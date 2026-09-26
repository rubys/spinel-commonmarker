/*
 * Native side of the commonmarker spin package, over the system
 * cmark-gfm (the C library comrak -- the gem's Rust core -- is a port of).
 *
 * A Commonmarker::Node holds a `native_struct` (CmarkNodeRef): one
 * cmark_node plus the OWNER that decides when the tree it lives in is
 * freed. cmark frees a node together with its subtree, and a node can be
 * reached after the edit that moved or detached it -- lobsters' Markdowner
 * inserts freshly made nodes into a parsed document, and deletes nodes
 * in the middle of a walk that still reads their children. So no node is
 * freed while any handle can reach it:
 *
 *   - An owner is created per parse (holding the document) and per
 *     Node.new (holding the one node). Every handle counts on its owner.
 *   - Moving a node from one owner's tree into another's MERGES the two:
 *     the moved-from owner forwards to the moved-into one and keeps a
 *     count on it, so the destination lives as long as any handle to
 *     either.
 *   - `delete` unlinks the node and lists it with its owner as a piece of
 *     its own.
 *   - When an owner's last handle goes, every listed piece that is still
 *     parentless is freed (with its subtree). A listed node that was later
 *     inserted somewhere has a parent, and is freed with that tree.
 *
 * Owner bookkeeping is under one mutex: finalizers may run on a GC sweeper
 * thread. cmark_node_free touches neither the Spinel heap nor Ruby.
 *
 * cmark-gfm itself is CARRIED, at 0.29.0.gfm.13, in cmark/ -- not linked
 * from the system -- so every machine parses with the same release (the
 * distro packages lag: Ubuntu 24.04 ships gfm.6, which differs from gfm.13
 * on HTML comments and HTML block types).
 *
 * RAW HTML UNDER `escape: true`. comrak's escape option renders raw HTML
 * as escaped text; cmark-gfm has no such option, and without UNSAFE it
 * writes `<!-- raw HTML omitted -->` in exactly those places, in document
 * order. So the render collects each raw-HTML node's literal in the same
 * order and substitutes the placeholders with the escaped literals. The
 * renderer's other safety (dropping `javascript:` URLs) is untouched,
 * which is what comrak does too. A user who writes the placeholder text
 * themselves wrote an HTML comment, which is itself a raw-HTML node, so
 * the order still lines up.
 */

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "spinel/runtime.h" /* sp_gc_alloc, sp_int, sp_bool */

/* cmark-gfm 0.29.0.gfm.13, carried in cmark/ (README, "How it is built"). */
#include "cmark/cmark-gfm.h"
#include "cmark/cmark-gfm-extension_api.h"
#include "cmark/cmark-gfm-core-extensions.h"

#define CM_NODE_HTML_BLOCK CMARK_NODE_HTML_BLOCK
#define CM_NODE_HTML_INLINE CMARK_NODE_HTML_INLINE
#define CM_EVENT_DONE CMARK_EVENT_DONE
#define CM_EVENT_ENTER CMARK_EVENT_ENTER

/* ---- extensions -------------------------------------------------------- */

/* The GFM extensions this package offers, in a fixed order; the Ruby side
   passes a bitmask over it. The render needs the same extension list the
   parse used (a table renders through its extension), and cmark hands one
   out only from a parser, so one parser per mask is built once and kept. */
static const char *const sp_cm_ext_names[] = {
	"table", "strikethrough", "autolink", "tagfilter", "tasklist"};
#define SP_CM_NEXT 5
#define SP_CM_NMASKS (1 << SP_CM_NEXT)

static pthread_once_t sp_cm_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t sp_cm_lock = PTHREAD_MUTEX_INITIALIZER;
static cmark_parser *sp_cm_ext_parsers[SP_CM_NMASKS];

static void sp_cm_init(void)
{
	cmark_gfm_core_extensions_ensure_registered();
}

static void sp_cm_attach(cmark_parser *p, sp_int mask)
{
	int i;
	for (i = 0; i < SP_CM_NEXT; i++) {
		if (mask & (1 << i)) {
			cmark_syntax_extension *e = cmark_find_syntax_extension(sp_cm_ext_names[i]);
			if (e)
				cmark_parser_attach_syntax_extension(p, e);
		}
	}
}

static cmark_llist *sp_cm_extensions(sp_int mask)
{
	cmark_llist *l;
	mask &= SP_CM_NMASKS - 1;
	pthread_mutex_lock(&sp_cm_lock);
	if (!sp_cm_ext_parsers[mask]) {
		sp_cm_ext_parsers[mask] = cmark_parser_new(0);
		sp_cm_attach(sp_cm_ext_parsers[mask], mask);
	}
	l = cmark_parser_get_syntax_extensions(sp_cm_ext_parsers[mask]);
	pthread_mutex_unlock(&sp_cm_lock);
	return l;
}

/* ---- owners ------------------------------------------------------------ */

typedef struct sp_cm_owner {
	long refs;
	struct sp_cm_owner *fwd;
	cmark_node **pieces;
	size_t n, cap;
} sp_cm_owner;

/* How many owners are alive: up per parse / Node.new, down when the last
   handle goes. Nothing reads it but test/finalizer.rb, which is how the
   release is observed at all. */
static long sp_cm_live_owners = 0;

sp_int sp_cmark_live_owners(void)
{
	return (sp_int)__atomic_load_n(&sp_cm_live_owners, __ATOMIC_RELAXED);
}

/* Callers hold sp_cm_lock. */
static sp_cm_owner *sp_cm_root(sp_cm_owner *o)
{
	while (o->fwd)
		o = o->fwd;
	return o;
}

static void sp_cm_list(sp_cm_owner *o, cmark_node *node)
{
	size_t i;
	for (i = 0; i < o->n; i++)
		if (o->pieces[i] == node)
			return;
	if (o->n == o->cap) {
		o->cap = o->cap ? o->cap * 2 : 4;
		o->pieces = (cmark_node **)realloc(o->pieces, o->cap * sizeof(cmark_node *));
	}
	o->pieces[o->n++] = node;
}

static sp_cm_owner *sp_cm_owner_new(cmark_node *node)
{
	sp_cm_owner *o = (sp_cm_owner *)calloc(1, sizeof(sp_cm_owner));
	sp_cm_list(o, node);
	__atomic_add_fetch(&sp_cm_live_owners, 1, __ATOMIC_RELAXED);
	return o;
}

/* Callers hold sp_cm_lock. */
static void sp_cm_release_locked(sp_cm_owner *o)
{
	while (o && --o->refs == 0) {
		sp_cm_owner *next = o->fwd;
		if (!next) {
			/* Decide EVERY piece's fate before freeing any: a listed
			   node that was inserted into another piece is freed with
			   that piece, so asking it for its parent after its tree
			   went would read freed memory. */
			size_t i, k = 0;
			for (i = 0; i < o->n; i++)
				if (cmark_node_parent(o->pieces[i]) == NULL)
					o->pieces[k++] = o->pieces[i];
			for (i = 0; i < k; i++)
				cmark_node_free(o->pieces[i]);
		}
		free(o->pieces);
		free(o);
		__atomic_sub_fetch(&sp_cm_live_owners, 1, __ATOMIC_RELAXED);
		o = next;
	}
}

/* `from`'s pieces now live in `into`'s tree: `from` forwards there, and
   keeps a count on it until its own handles are gone. */
static void sp_cm_merge_locked(sp_cm_owner *from, sp_cm_owner *into)
{
	size_t i;
	from = sp_cm_root(from);
	into = sp_cm_root(into);
	if (from == into)
		return;
	for (i = 0; i < from->n; i++)
		sp_cm_list(into, from->pieces[i]);
	from->n = 0;
	from->fwd = into;
	into->refs++;
}

/* ---- Commonmarker::Node ------------------------------------------------- */

typedef struct sp_CmarkNode_s {
	sp_int cls_id;
	cmark_node *node;
	sp_cm_owner *owner;
} sp_CmarkNode;

void sp_CmarkNode_fin(void *p)
{
	sp_CmarkNode *s = (sp_CmarkNode *)p;
	if (s && s->owner) {
		pthread_mutex_lock(&sp_cm_lock);
		sp_cm_release_locked(s->owner);
		pthread_mutex_unlock(&sp_cm_lock);
		s->owner = NULL;
		s->node = NULL;
	}
}

sp_CmarkNode *sp_CmarkNode_new(sp_int cls_id)
{
	sp_CmarkNode *s = (sp_CmarkNode *)sp_gc_alloc(sizeof(sp_CmarkNode), sp_CmarkNode_fin, NULL);
	s->cls_id = cls_id;
	s->node = NULL;
	s->owner = NULL;
	return s;
}

/* A fresh handle on `node` counting on `owner` (NULL node: an empty
   handle, which the Ruby side reads as nil). */
static sp_CmarkNode *sp_cm_wrap(sp_int cls_id, cmark_node *node, sp_cm_owner *owner)
{
	sp_CmarkNode *s = sp_CmarkNode_new(cls_id);
	if (node && owner) {
		pthread_mutex_lock(&sp_cm_lock);
		owner = sp_cm_root(owner);
		owner->refs++;
		pthread_mutex_unlock(&sp_cm_lock);
		s->node = node;
		s->owner = owner;
	}
	return s;
}

sp_bool sp_CmarkNode_present_p(sp_CmarkNode *self)
{
	return self->node != NULL;
}

/* Commonmarker.parse: `options` are cmark parse options, `ext` the
   extension mask. */
sp_CmarkNode *sp_CmarkNode_parse(sp_CmarkNode *self, const char *text, sp_int options, sp_int ext)
{
	cmark_parser *p;
	cmark_node *doc;
	sp_cm_owner *o;
	pthread_once(&sp_cm_once, sp_cm_init);
	p = cmark_parser_new((int)options);
	sp_cm_attach(p, ext);
	cmark_parser_feed(p, text, strlen(text));
	doc = cmark_parser_finish(p);
	cmark_parser_free(p);
	o = sp_cm_owner_new(doc);
	return sp_cm_wrap(self->cls_id, doc, o);
}

/* Node.new(type): a detached node of a core type. */
sp_CmarkNode *sp_CmarkNode_make(sp_CmarkNode *self, sp_int type)
{
	cmark_node *n;
	pthread_once(&sp_cm_once, sp_cm_init);
	n = cmark_node_new((cmark_node_type)type);
	if (!n)
		return sp_CmarkNode_new(self->cls_id);
	return sp_cm_wrap(self->cls_id, n, sp_cm_owner_new(n));
}

const char *sp_CmarkNode_type_string(sp_CmarkNode *self)
{
	return cmark_node_get_type_string(self->node);
}

sp_int sp_CmarkNode_type_code(sp_CmarkNode *self)
{
	return (sp_int)cmark_node_get_type(self->node);
}

sp_int sp_CmarkNode_heading_level(sp_CmarkNode *self)
{
	return cmark_node_get_heading_level(self->node);
}

sp_CmarkNode *sp_CmarkNode_first_child(sp_CmarkNode *self)
{
	return sp_cm_wrap(self->cls_id, cmark_node_first_child(self->node), self->owner);
}

sp_CmarkNode *sp_CmarkNode_last_child(sp_CmarkNode *self)
{
	return sp_cm_wrap(self->cls_id, cmark_node_last_child(self->node), self->owner);
}

sp_CmarkNode *sp_CmarkNode_next_sibling(sp_CmarkNode *self)
{
	return sp_cm_wrap(self->cls_id, cmark_node_next(self->node), self->owner);
}

sp_CmarkNode *sp_CmarkNode_previous_sibling(sp_CmarkNode *self)
{
	return sp_cm_wrap(self->cls_id, cmark_node_previous(self->node), self->owner);
}

sp_CmarkNode *sp_CmarkNode_parent(sp_CmarkNode *self)
{
	return sp_cm_wrap(self->cls_id, cmark_node_parent(self->node), self->owner);
}

/* A node argument arrives boxed (`native_method` spec :any); the box holds
   the handle. */
static sp_CmarkNode *sp_cm_arg(sp_RbVal v)
{
	return (sp_CmarkNode *)v.v.p;
}

sp_bool sp_CmarkNode_same_p(sp_CmarkNode *self, sp_RbVal other)
{
	return self->node == sp_cm_arg(other)->node;
}

const char *sp_CmarkNode_literal(sp_CmarkNode *self)
{
	const char *s = cmark_node_get_literal(self->node);
	return s ? s : "";
}

sp_bool sp_CmarkNode_set_literal(sp_CmarkNode *self, const char *s)
{
	return cmark_node_set_literal(self->node, s) != 0;
}

const char *sp_CmarkNode_url(sp_CmarkNode *self)
{
	const char *s = cmark_node_get_url(self->node);
	return s ? s : "";
}

sp_bool sp_CmarkNode_set_url(sp_CmarkNode *self, const char *s)
{
	return cmark_node_set_url(self->node, s) != 0;
}

const char *sp_CmarkNode_title(sp_CmarkNode *self)
{
	const char *s = cmark_node_get_title(self->node);
	return s ? s : "";
}

sp_bool sp_CmarkNode_set_title(sp_CmarkNode *self, const char *s)
{
	return cmark_node_set_title(self->node, s) != 0;
}

/* The tree edits. cmark refuses an edit that would make a cycle or put a
   block inside an inline (answering 0); on success the moved node's owner
   is merged into the receiver's. */
static sp_bool sp_cm_moved(sp_CmarkNode *self, sp_CmarkNode *other, int ok)
{
	if (ok) {
		pthread_mutex_lock(&sp_cm_lock);
		sp_cm_merge_locked(other->owner, self->owner);
		pthread_mutex_unlock(&sp_cm_lock);
	}
	return ok != 0;
}

sp_bool sp_CmarkNode_insert_before(sp_CmarkNode *self, sp_RbVal arg)
{
	sp_CmarkNode *other = sp_cm_arg(arg);
	return sp_cm_moved(self, other, cmark_node_insert_before(self->node, other->node));
}

sp_bool sp_CmarkNode_insert_after(sp_CmarkNode *self, sp_RbVal arg)
{
	sp_CmarkNode *other = sp_cm_arg(arg);
	return sp_cm_moved(self, other, cmark_node_insert_after(self->node, other->node));
}

sp_bool sp_CmarkNode_append_child(sp_CmarkNode *self, sp_RbVal arg)
{
	sp_CmarkNode *other = sp_cm_arg(arg);
	return sp_cm_moved(self, other, cmark_node_append_child(self->node, other->node));
}

sp_bool sp_CmarkNode_prepend_child(sp_CmarkNode *self, sp_RbVal arg)
{
	sp_CmarkNode *other = sp_cm_arg(arg);
	return sp_cm_moved(self, other, cmark_node_prepend_child(self->node, other->node));
}

/* `delete`: unlinked, and listed with its owner as a piece of its own --
   still readable through any handle, freed when the owner goes. */
void sp_CmarkNode_unlink(sp_CmarkNode *self)
{
	cmark_node_unlink(self->node);
	pthread_mutex_lock(&sp_cm_lock);
	sp_cm_list(sp_cm_root(self->owner), self->node);
	pthread_mutex_unlock(&sp_cm_lock);
}

/* ---- rendering --------------------------------------------------------- */

/* Rendered text is returned through a per-thread buffer the FFI copies out
   at the boundary. */
static SP_TLS char *sp_cm_out = NULL;

static void sp_cm_set_out(char *s)
{
	free(sp_cm_out);
	sp_cm_out = s;
}

/* `&`, `<`, `>` and `"` -- what comrak's escape option escapes. */
static void sp_cm_escape(const char *s, size_t n, char **buf, size_t *len, size_t *cap)
{
	size_t i;
	for (i = 0; i < n; i++) {
		const char *rep = NULL;
		size_t rl;
		switch (s[i]) {
		case '&': rep = "&amp;"; break;
		case '<': rep = "&lt;"; break;
		case '>': rep = "&gt;"; break;
		case '"': rep = "&quot;"; break;
		}
		rl = rep ? strlen(rep) : 1;
		if (*len + rl + 1 > *cap) {
			*cap = (*len + rl + 1) * 2;
			*buf = (char *)realloc(*buf, *cap);
		}
		if (rep)
			memcpy(*buf + *len, rep, rl);
		else
			(*buf)[*len] = s[i];
		*len += rl;
	}
	(*buf)[*len] = 0;
}

static const char SP_CM_OMITTED[] = "<!-- raw HTML omitted -->";

/* `escape: true`: substitute each placeholder, in order, with the escaped
   literal of the raw-HTML node that produced it. A block's literal ends in
   the newline the renderer also writes after the placeholder, so one is
   dropped from the block's. */
static char *sp_cm_substitute(cmark_node *root, char *html)
{
	cmark_iter *it = cmark_iter_new(root);
	char *out = NULL;
	size_t len = 0, cap = 0;
	const char *cursor = html;
	cmark_event_type ev;
	while ((ev = cmark_iter_next(it)) != CM_EVENT_DONE) {
		cmark_node *n;
		cmark_node_type t;
		const char *lit, *hit;
		size_t ln;
		if (ev != CM_EVENT_ENTER)
			continue;
		n = cmark_iter_get_node(it);
		t = cmark_node_get_type(n);
		if (t != CM_NODE_HTML_INLINE && t != CM_NODE_HTML_BLOCK)
			continue;
		hit = strstr(cursor, SP_CM_OMITTED);
		if (!hit)
			break;
		/* the text before the placeholder, verbatim */
		{
			size_t pre = (size_t)(hit - cursor);
			if (len + pre + 1 > cap) {
				cap = (len + pre + 1) * 2;
				out = (char *)realloc(out, cap);
			}
			memcpy(out + len, cursor, pre);
			len += pre;
			out[len] = 0;
		}
		lit = cmark_node_get_literal(n);
		if (!lit)
			lit = "";
		ln = strlen(lit);
		if (t == CM_NODE_HTML_BLOCK && ln > 0 && lit[ln - 1] == '\n')
			ln--;
		sp_cm_escape(lit, ln, &out, &len, &cap);
		cursor = hit + sizeof(SP_CM_OMITTED) - 1;
	}
	cmark_iter_free(it);
	{
		size_t rest = strlen(cursor);
		if (len + rest + 1 > cap) {
			cap = len + rest + 1;
			out = (char *)realloc(out, cap);
		}
		memcpy(out + len, cursor, rest);
		len += rest;
		out[len] = 0;
	}
	free(html);
	return out;
}

/* `escape` is 1 for the comrak option; `options` are cmark render options
   (the Ruby side has already refused what cmark cannot render). */
sp_int sp_CmarkNode_render_html(sp_CmarkNode *self, sp_int options, sp_int ext, sp_int escape)
{
	char *html = cmark_render_html(self->node, (int)options, sp_cm_extensions(ext));
	if (escape)
		html = sp_cm_substitute(self->node, html);
	sp_cm_set_out(html);
	return (sp_int)strlen(html);
}

sp_int sp_CmarkNode_render_commonmark(sp_CmarkNode *self, sp_int options, sp_int width)
{
	char *md = cmark_render_commonmark(self->node, (int)options, (int)width);
	sp_cm_set_out(md);
	return (sp_int)strlen(md);
}

const char *sp_cmark_rendered(void)
{
	return sp_cm_out ? sp_cm_out : "";
}

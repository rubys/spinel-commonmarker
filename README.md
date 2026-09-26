# commonmarker (spinel-commonmarker)

A subset of the [commonmarker](https://github.com/gjtorikian/commonmarker)
gem (2.x) for Spinel, over [cmark-gfm](https://github.com/github/cmark-gfm)
0.29.0.gfm.13, which the package carries and compiles itself. The require string is
`commonmarker` and the names are the gem's, so code written against the
gem resolves here unchanged — lobsters' `Markdowner` was the first user,
and it parses, walks and edits the tree before rendering it:

```ruby
require "commonmarker"

OPTIONS = {
  extension: { tagfilter: true, autolink: true, strikethrough: true, header_ids: nil, shortcodes: nil },
  render: { escape: true, hardbreaks: false, escaped_char_spans: false },
}

root = Commonmarker.parse("Hello @alice, *see* <b>this</b>", options: OPTIONS)
root.walk { |n| p n.type }                 # :document, :paragraph, :text, :emph, ...

text = root.first_child.first_child        # the "Hello @alice, " text node
link = Commonmarker::Node.new(:link, url: "https://example.test/~alice")
label = Commonmarker::Node.new(:text)
label.string_content = "@alice"
link.append_child(label)
text.string_content = "Hello "
text.insert_after(link)

root.to_html(options: OPTIONS, plugins: { syntax_highlighter: nil })
# => "<p>Hello <a href=\"https://example.test/~alice\">@alice</a>, <em>see</em> &lt;b&gt;this&lt;/b&gt;</p>\n"

Commonmarker.to_html(markdown, options: OPTIONS, plugins: { syntax_highlighter: nil })
root.to_commonmark                          # see "Divergences"
```

## Why cmark-gfm

The gem binds [comrak](https://github.com/kivikakk/comrak), a Rust port
of cmark-gfm that checks itself against cmark-gfm's spec suite. Binding
comrak itself would mean a Rust static library with a hand-written C
surface; cmark-gfm is a C library a distro already packages. The two
render alike: 400 lobsters comments, bios and story descriptions, and
all but the 22 spec examples listed below, are byte-identical — see
`test/corpus_test.rb`.

## How it is built

`Commonmarker::Node` is an ordinary Ruby class holding a `native_struct`
(`CmarkNodeRef`): one `cmark_node` plus the **owner** that decides when
the tree it lives in is freed. cmark frees a node with its subtree, and a
node can be reached after the edit that moved or detached it — lobsters
inserts freshly made nodes into a parsed document, and deletes nodes in
the middle of a walk that still reads their children. So nothing is freed
while any handle can reach it:

- a parse and each `Node.new` make an owner, and every handle counts on
  its owner;
- moving a node into another owner's tree merges the two (the moved-from
  owner forwards to the other and keeps a count on it);
- `delete` unlinks the node and lists it with its owner as a piece of its
  own, still readable;
- when an owner's last handle goes, every listed piece that is still
  parentless is freed with its subtree.

The bookkeeping is under one mutex, because finalizers may run on a GC
sweeper thread. `test/finalizer.rb` makes eight thousand owners through
Markdowner's edits and checks that a collection releases them.

`walk` and `each` are the gem's own Ruby (its `node.rb`), with one change:
`walk` is the same traversal written without recursion. Spinel inlines a
method that uses its block, and a recursive one cannot be inlined. The
ORDER of reads is the gem's, which is what Markdowner relies on: a node is
visited, then its first child is read (so an edit the block made is seen),
and each child's next sibling is read before that child is visited (so
moving or deleting it does not derail the walk).

**`render: { escape: true }`** — raw HTML rendered as escaped text — is
comrak's and has no cmark-gfm equivalent. Without `unsafe`, cmark-gfm
writes `<!-- raw HTML omitted -->` where each raw-HTML node was, in
document order; the render collects each node's literal in the same order
and substitutes the escaped literal (`&`, `<`, `>`, `"` — what comrak
escapes). cmark-gfm's other safety, dropping `javascript:` URLs, is left
as it is, which is also comrak's behaviour.

**cmark-gfm is carried, not linked from the system**, in `cmark/`: the
0.29.0.gfm.13 release's `src/` and `extensions/` in one directory (minus
the CLI's `main.c`), with the three headers its cmake build generates
(`config.h`, `cmark-gfm_export.h`, `cmark-gfm_version.h`, which are the
same on macOS and Linux) and its `COPYING`. Distro packages lag the
release — Ubuntu 24.04 ships gfm.6, which parses HTML comments and some
HTML block types differently from gfm.13 (five spec examples) — so a
system library would make the output depend on the machine. The one edit
to the sources is `cmark/include-paths.patch`: the extensions include a
few core headers with angle brackets (`<parser.h>`), which only a
`-I src` finds, and `spin` compiles carried C with `-I <package>` alone,
so those lines use quotes.

## Requirements

A C compiler; nothing else — cmark-gfm is compiled from `cmark/` with the
package.

Spinel with matz/spinel#5074 fixed: before it, `Hash#key?` answered false
on the options the caller passes, so every option read as its default.

## Subset vs commonmarker

- `Commonmarker.parse`, `Commonmarker.to_html`; `Node.new` for the core
  node types (`:text`, `:link`, `:image`, `:emph`, `:strong`, `:code`,
  `:paragraph`, …, with `url:` / `title:`); `type`, `first_child`,
  `last_child`, `next_sibling`, `previous_sibling`, `parent`, `==`,
  `string_content` (and `=`), `url` / `title` (and `=`), `header_level`,
  `insert_before`, `insert_after`, `append_child`, `prepend_child`,
  `delete`, `walk`, `each`, `to_html`, `to_commonmark`.
- Extensions: `table`, `strikethrough`, `autolink`, `tagfilter`,
  `tasklist`. Render options: `hardbreaks`, `github_pre_lang`,
  `full_info_string`, `unsafe`, `escape`, `width`. Parse option: `smart`.
- An option cmark-gfm cannot honour raises `ArgumentError` when it is
  on — in the phase it affects, so an option that cannot change the
  output being made is not an error. The gem's DEFAULTS turn three such
  options on (`shortcodes: true` for parsing, `header_ids: ""` and
  `escaped_char_spans: true` for HTML), so a bare
  `Commonmarker.to_html(text)` raises; pass the options you use.
- No `Enumerable` on `Node`, no `inspect` tree dump, no `sourcepos`, no
  syntax highlighter (`plugins: { syntax_highlighter: nil }` is accepted).

## Divergences

Known, and kept visible:

- **`to_commonmark`** uses cmark-gfm's CommonMark writer; comrak has its
  own (`cm.rs`). They differ in which characters get a backslash (comrak
  writes `\@`, cmark-gfm `\~`), whether a soft break survives at width 80
  (comrak keeps the newline), and list markers (`- a` / `1. a` against
  `  - a` / `1.  a`). `divergence/commonmark.rb` and its `.gem` output
  show the cases.
- **22 spec examples** (named in `test/corpus_test.rb`'s `KNOWN`):
  - nested `<strong>` — cmark-gfm's HTML renderer never writes a
    `<strong>` directly inside another (a GitHub quirk with no switch),
    so `****foo****` renders as `<strong>foo</strong>` (9 in each spec);
  - `&#87654321;` — cmark-gfm decodes an out-of-range character
    reference to U+FFFD, comrak (spec 0.31) leaves it as text;
  - `*£*bravo` — spec 0.31 counts currency symbols as punctuation for
    emphasis; cmark-gfm implements 0.29;
  - `<foo\+@bar.example.com>` — cmark-gfm's autolink extension links the
    backslash-escaped address, comrak does not.

## Tests

```sh
spin test          # compiled port against the committed snapshots
sh oracle/run.sh   # the SAME test files under CRuby with the real gem
```

`test/*_test.rb` are the conformance tests; their snapshots are the gem's
answers, frozen, and the compiled port is held to them. No hand-authored
expectations. `test/finalizer.rb` has no gem count to compare, so it has
no `_test` suffix and the oracle skips it.

Corpora: `test/corpus/commonmark_spec.txt` is the CommonMark 0.31.2 spec's
652 examples (spec.commonmark.org, CC BY-SA 4.0);
`test/corpus/gfm_spec.txt` is the 672 examples of cmark-gfm's GFM spec
(CC BY-SA 4.0); `test/corpus/lobsters_fake_data.txt` is 400 records from
lobsters' fake-data generator.

## License

MIT, like the gem. `cmark/` is cmark-gfm's, under its own license
(`cmark/COPYING`, BSD-2-Clause and others).

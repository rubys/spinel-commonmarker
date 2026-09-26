# commonmarker for Spinel — a subset of the commonmarker gem (2.x) over the
# system cmark-gfm, bound through the carried C in sp_cmark.c. The require
# string is "commonmarker" and the names are the gem's, so code written
# against the gem — lobsters' Markdowner, which parses, walks and edits the
# tree before rendering it — resolves here unchanged.
#
# The gem is a binding to comrak, a Rust port of cmark-gfm that checks
# itself against cmark-gfm's spec suite, so the two render alike; where
# they do not, it is written down in the README and refused or converted
# here rather than left to differ silently:
#
# - an option cmark-gfm has no equivalent for raises ArgumentError when it
#   is on (the gem's DEFAULTS turn two of them on — `header_ids: ""` and
#   `shortcodes: true` — so a bare `Commonmarker.to_html(text)` raises;
#   pass the options you use, as lobsters does);
# - `render: { escape: true }` (raw HTML as escaped text) is done by
#   sp_cmark.c, since cmark-gfm has no such option.

module CommonmarkerExt
  ffi_lib "cmark-gfm"
  ffi_lib "cmark-gfm-extensions"
  ffi_cflags "-L/opt/homebrew/lib -L/usr/local/lib"

  ffi_func :sp_cmark_rendered,    [], :str
  ffi_func :sp_cmark_live_owners, [], :int
end

# The native half of Commonmarker::Node: one cmark node and the owner that
# keeps its tree alive (see sp_cmark.c). Its own top-level name, for the
# reason spinel-ruby-vips gives: a native class is keyed by its last
# segment, so a native `Commonmarker::Node` would merge with any other
# `Node` in the program.
module CommonmarkerNodePackage
  native_struct "CmarkNodeRef", "sp_CmarkNode", "sp_CmarkNode_fin"
  native_new [], "sp_CmarkNode_new"

  native_method :__present?,        [], :bool,                  "sp_CmarkNode_present_p"
  native_method :__parse,           [:string, :int, :int], :self, "sp_CmarkNode_parse"
  native_method :__make,            [:int], :self,              "sp_CmarkNode_make"
  native_method :__type_string,     [], :string,                "sp_CmarkNode_type_string"
  native_method :__type_code,       [], :int,                   "sp_CmarkNode_type_code"
  native_method :__heading_level,   [], :int,                   "sp_CmarkNode_heading_level"
  native_method :__first_child,     [], :self,                  "sp_CmarkNode_first_child"
  native_method :__last_child,      [], :self,                  "sp_CmarkNode_last_child"
  native_method :__next_sibling,    [], :self,                  "sp_CmarkNode_next_sibling"
  native_method :__previous_sibling, [], :self,                 "sp_CmarkNode_previous_sibling"
  native_method :__parent,          [], :self,                  "sp_CmarkNode_parent"
  native_method :__same?,           [:any], :bool,             "sp_CmarkNode_same_p"
  native_method :__literal,         [], :string,                "sp_CmarkNode_literal"
  native_method :__set_literal,     [:string], :bool,           "sp_CmarkNode_set_literal"
  native_method :__url,             [], :string,                "sp_CmarkNode_url"
  native_method :__set_url,         [:string], :bool,           "sp_CmarkNode_set_url"
  native_method :__title,           [], :string,                "sp_CmarkNode_title"
  native_method :__set_title,       [:string], :bool,           "sp_CmarkNode_set_title"
  native_method :__insert_before,   [:any], :bool,             "sp_CmarkNode_insert_before"
  native_method :__insert_after,    [:any], :bool,             "sp_CmarkNode_insert_after"
  native_method :__append_child,    [:any], :bool,             "sp_CmarkNode_append_child"
  native_method :__prepend_child,   [:any], :bool,             "sp_CmarkNode_prepend_child"
  native_method :__unlink,          [], :void,                  "sp_CmarkNode_unlink"
  native_method :__render_html,     [:int, :int, :int], :int,   "sp_CmarkNode_render_html"
  native_method :__render_commonmark, [:int, :int], :int,       "sp_CmarkNode_render_commonmark"
end

module Commonmarker
  # The gem's default options, verbatim (commonmarker 2.6.3).
  module Config
    OPTIONS = {
      parse: {
        smart: false,
        default_info_string: "",
        relaxed_tasklist_matching: false,
        relaxed_autolinks: false,
        leave_footnote_definitions: false,
        ignore_setext: false,
      },
      render: {
        hardbreaks: true,
        github_pre_lang: true,
        full_info_string: false,
        width: 80,
        unsafe: false,
        escape: false,
        sourcepos: false,
        escaped_char_spans: true,
        ignore_empty_links: false,
        gfm_quirks: false,
        prefer_fenced: false,
        tasklist_classes: false,
      },
      extension: {
        strikethrough: true,
        tagfilter: true,
        table: true,
        autolink: true,
        tasklist: true,
        superscript: false,
        header_ids: "",
        footnotes: false,
        inline_footnotes: false,
        description_lists: false,
        front_matter_delimiter: "",
        multiline_block_quotes: false,
        math_dollars: false,
        math_code: false,
        shortcodes: true,
        wikilinks_title_before_pipe: false,
        wikilinks_title_after_pipe: false,
        underline: false,
        spoiler: false,
        greentext: false,
        subscript: false,
        subtext: false,
        alerts: false,
        cjk_friendly_emphasis: false,
        highlight: false,
      },
      format: [:html],
    }

    PLUGINS = { syntax_highlighter: nil }

    # cmark option bits (cmark-gfm.h).
    OPT_SOURCEPOS = 1 << 1
    OPT_HARDBREAKS = 1 << 2
    OPT_SMART = 1 << 10
    OPT_GITHUB_PRE_LANG = 1 << 11
    OPT_FULL_INFO_STRING = 1 << 16
    OPT_UNSAFE = 1 << 17

    # The extension mask sp_cmark.c reads, in its order.
    EXTENSION_BITS = { table: 1, strikethrough: 2, autolink: 4, tagfilter: 8, tasklist: 16 }

    # A value that turns an option on: true, or a non-empty String (the gem
    # spells "off" as false, nil or "").
    def self.on?(v)
      return false if v.nil? || v == false
      return !v.empty? if v.is_a?(String)
      true
    end

    def self.value(options, group, key)
      g = options[group]
      if !g.nil? && g.key?(key)
        g[key]
      else
        OPTIONS[group][key]
      end
    end

    def self.refuse(options, group, keys)
      keys.each do |k|
        if on?(value(options, group, k))
          raise ArgumentError, "commonmarker (spinel): #{group} option #{k} is not supported"
        end
      end
      nil
    end

    # Each refusal is for the PHASE the option changes, so an option that
    # cannot matter to the output being made is not an error: lobsters
    # renders to_raw's CommonMark with the gem's defaults, where
    # `shortcodes` (parse-time) was already off for its parse and
    # `header_ids` / `escaped_char_spans` shape only HTML.

    # Options that change the TREE: refused at parse.
    def self.parse_flags(options)
      refuse(options, :parse, [:default_info_string, :relaxed_tasklist_matching, :relaxed_autolinks,
                               :leave_footnote_definitions, :ignore_setext])
      refuse(options, :extension, [:superscript, :footnotes, :inline_footnotes, :description_lists,
                                   :front_matter_delimiter, :multiline_block_quotes, :math_dollars,
                                   :math_code, :shortcodes, :wikilinks_title_before_pipe,
                                   :wikilinks_title_after_pipe, :underline, :spoiler, :greentext,
                                   :subscript, :subtext, :alerts, :cjk_friendly_emphasis, :highlight])
      on?(value(options, :parse, :smart)) ? OPT_SMART : 0
    end

    def self.extension_mask(options)
      mask = 0
      EXTENSION_BITS.each { |k, bit| mask |= bit if on?(value(options, :extension, k)) }
      mask
    end

    # Options that change the HTML: refused at to_html.
    def self.html_flags(options)
      refuse(options, :render, [:sourcepos, :escaped_char_spans, :ignore_empty_links, :gfm_quirks,
                                :prefer_fenced, :tasklist_classes])
      refuse(options, :extension, [:header_ids])
      f = 0
      f |= OPT_HARDBREAKS if on?(value(options, :render, :hardbreaks))
      f |= OPT_GITHUB_PRE_LANG if on?(value(options, :render, :github_pre_lang))
      f |= OPT_FULL_INFO_STRING if on?(value(options, :render, :full_info_string))
      f |= OPT_UNSAFE if on?(value(options, :render, :unsafe))
      f
    end

    def self.escape?(options)
      on?(value(options, :render, :escape)) && !on?(value(options, :render, :unsafe))
    end

    def self.width(options)
      w = value(options, :render, :width)
      w.nil? ? 0 : w.to_i
    end

    def self.check_plugins(plugins)
      unless plugins[:syntax_highlighter].nil?
        raise ArgumentError, "commonmarker (spinel): the syntax_highlighter plugin is not supported"
      end
      nil
    end
  end

  def self.parse(text, options: Config::OPTIONS)
    flags = Config.parse_flags(options)
    mask = Config.extension_mask(options)
    Node.new(nil, ref: CmarkNodeRef.new.__parse(text.to_s, flags, mask))
  end

  def self.to_html(text, options: Config::OPTIONS, plugins: Config::PLUGINS)
    parse(text, options: options).to_html(options: options, plugins: plugins)
  end

  class Node
    # Core node types by the gem's names, for Node.new (cmark-gfm.h).
    TYPE_CODES = {
      document: 0x8001, block_quote: 0x8002, list: 0x8003, item: 0x8004,
      code_block: 0x8005, html_block: 0x8006, paragraph: 0x8008, heading: 0x8009,
      thematic_break: 0x800a, text: 0xc001, softbreak: 0xc002, linebreak: 0xc003,
      code: 0xc004, html_inline: 0xc005, emph: 0xc007, strong: 0xc008,
      link: 0xc009, image: 0xc00a,
    }

    # The gem's `Node.new(:link, url: …, title: …)` / `Node.new(:text)`.
    # `ref:` is this package's own: a handle the native side made.
    def initialize(type = nil, url: nil, title: nil, ref: nil)
      if ref.nil?
        code = TYPE_CODES[type]
        raise ArgumentError, "commonmarker (spinel): cannot make a #{type} node" if code.nil?
        ref = CmarkNodeRef.new.__make(code)
        ref.__set_url(url.to_s) unless url.nil?
        ref.__set_title(title.to_s) unless title.nil?
      end
      @ref = ref
    end

    def __ref
      @ref
    end

    # A handle from the native side, or nil when it holds no node.
    def self.wrap(ref)
      ref.__present? ? Node.new(nil, ref: ref) : nil
    end

    # The gem's type symbols. cmark-gfm's names match comrak's except the
    # four below.
    def type
      s = @ref.__type_string
      return :thematic_break if s == "thematic_break"
      return :taskitem if s == "tasklist"
      return :table_row if s == "table_header" || s == "table_row"
      return :table_cell if s == "table_cell"
      type_symbol(s)
    end

    def first_child
      Node.wrap(@ref.__first_child)
    end

    def last_child
      Node.wrap(@ref.__last_child)
    end

    def next_sibling
      Node.wrap(@ref.__next_sibling)
    end

    def previous_sibling
      Node.wrap(@ref.__previous_sibling)
    end

    def parent
      Node.wrap(@ref.__parent)
    end

    def ==(other)
      other.is_a?(Node) && @ref.__same?(other.__ref)
    end

    def header_level
      @ref.__heading_level
    end

    def string_content
      @ref.__literal
    end

    def string_content=(s)
      raise TypeError, "could not set string content" unless @ref.__set_literal(s.to_s)
      s
    end

    def url
      @ref.__url
    end

    def url=(s)
      raise TypeError, "could not set url" unless @ref.__set_url(s.to_s)
      s
    end

    def title
      @ref.__title
    end

    def title=(s)
      raise TypeError, "could not set title" unless @ref.__set_title(s.to_s)
      s
    end

    def insert_before(node)
      raise TypeError, "could not insert before" unless @ref.__insert_before(node.__ref)
      true
    end

    def insert_after(node)
      raise TypeError, "could not insert after" unless @ref.__insert_after(node.__ref)
      true
    end

    def append_child(node)
      raise TypeError, "could not append child" unless @ref.__append_child(node.__ref)
      true
    end

    def prepend_child(node)
      raise TypeError, "could not prepend child" unless @ref.__prepend_child(node.__ref)
      true
    end

    def delete
      @ref.__unlink
      nil
    end

    # The gem's `walk` (node.rb: `yield self; each { |c| c.walk(&block) }`)
    # as the same traversal without the recursion — spinel inlines a
    # method that uses its block, and a recursive one cannot be inlined.
    # The ORDER of reads is the gem's, because Markdowner edits the tree
    # from inside the block: a node is visited, then its first child is
    # read (after the block ran, so an edit made there is seen), and each
    # child's next sibling is read BEFORE that child is visited (so moving
    # or deleting the child does not derail the iteration). `pending` holds
    # the sibling to resume at once a subtree is done.
    def walk(&block)
      block.call(self)
      pending = []
      child = first_child
      while true
        if child.nil?
          break if pending.empty?
          child = pending.pop
          next
        end
        after = child.next_sibling
        block.call(child)
        pending.push(after)
        child = child.first_child
      end
      nil
    end

    def each
      child = first_child
      while child
        next_child = child.next_sibling
        yield child
        child = next_child
      end
    end

    def to_html(options: Config::OPTIONS, plugins: Config::PLUGINS)
      Config.check_plugins(plugins)
      mask = Config.extension_mask(options)
      flags = Config.html_flags(options)
      @ref.__render_html(flags, mask, Config.escape?(options) ? 1 : 0)
      CommonmarkerExt.sp_cmark_rendered
    end

    def to_commonmark(options: Config::OPTIONS, plugins: Config::PLUGINS)
      Config.check_plugins(plugins)
      # comrak's CommonMark renderer takes the width and nothing else here
      # (a soft break stays a newline under the default `hardbreaks: true`).
      @ref.__render_commonmark(0, Config.width(options))
      CommonmarkerExt.sp_cmark_rendered
    end

    private

    def type_symbol(s)
      case s
      when "document" then :document
      when "block_quote" then :block_quote
      when "list" then :list
      when "item" then :item
      when "code_block" then :code_block
      when "html_block" then :html_block
      when "paragraph" then :paragraph
      when "heading" then :heading
      when "text" then :text
      when "softbreak" then :softbreak
      when "linebreak" then :linebreak
      when "code" then :code
      when "html_inline" then :html_inline
      when "emph" then :emph
      when "strong" then :strong
      when "link" then :link
      when "image" then :image
      when "strikethrough" then :strikethrough
      when "table" then :table
      when "footnote_definition" then :footnote_definition
      when "footnote_reference" then :footnote_reference
      else :unknown
      end
    end
  end
end

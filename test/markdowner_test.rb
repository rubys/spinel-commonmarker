# lobsters' Markdowner, the shapes it drives commonmarker through: parse
# with its options, walk the text nodes and split `@user` mentions into
# link nodes made with Node.new (insert_after / append_child /
# string_content=), render HTML; and its to_raw, which unwraps links,
# images and emphasis DURING a walk (insert_before the first child, then
# delete). to_raw's tree is shown as HTML here: its CommonMark rendering
# is the one known divergence (README, test/commonmark.rb). Every line is
# the gem's answer (`sh oracle/run.sh`); `spin test` holds the port to it.
require "commonmarker"

OPTIONS = {
  extension: { tagfilter: true, autolink: true, strikethrough: true, header_ids: nil, shortcodes: nil },
  render: { escape: true, hardbreaks: false, escaped_char_spans: false },
}

def walk_text_nodes(node, &block)
  return if node.type == :link
  return block.call(node) if node.type == :text
  node.each do |child|
    walk_text_nodes(child, &block)
  end
end

def link_mentions(node)
  while node
    return unless node.string_content =~ /\B([@~][A-Za-z0-9_\-]+)\b/
    before, user, after = $`, $1, $'
    node.string_content = before
    link = Commonmarker::Node.new(:link, url: "https://example.test/~" + user[1..].downcase)
    node.insert_after(link)
    text = Commonmarker::Node.new(:text)
    text.string_content = user
    link.append_child(text)
    node = link
    if after.length > 0
      rest = Commonmarker::Node.new(:text)
      rest.string_content = after
      node.insert_after(rest)
      node = rest
    else
      node = nil
    end
  end
end

def to_html(text)
  root = Commonmarker.parse(text, options: OPTIONS)
  walk_text_nodes(root) { |n| link_mentions(n) }
  root.to_html(options: OPTIONS, plugins: { syntax_highlighter: nil })
end

def unwrapped(text)
  root = Commonmarker.parse(text, options: OPTIONS)
  root.walk do |node|
    if node.type == :image || node.type == :link || node.type == :emph ||
        node.type == :strong || node.type == :strikethrough
      node.insert_before(node.first_child)
      node.delete
    end
  end
  root
end

CASES = [
  "Hello @alice, see ~bob's post.",
  "no mentions here",
  "@first and a [link to @notme](http://x.test) then @last",
  "*emph @inside* and **strong** text",
  "A paragraph.\n\nAnother with @carol\nand a soft break.",
  "Quote:\n\n> @dave said *so*",
  "Raw <b>html</b> & entities &amp; \"quotes\"",
  "<div>\nblock html @ignored\n</div>\n\nafter",
  "~~struck~~ www.example.com and https://example.org/x?y=1",
  "`code @notuser` and ```\nfenced @no\n```",
  "![alt text](http://img.test/a.png \"title\") [plain](http://l.test)",
  "- one *a*\n- two **b**\n\n1. first\n2. second",
  "# Heading @h\n\nbody",
  "",
]

CASES.each do |t|
  puts "== #{t.inspect}"
  puts to_html(t).inspect
  puts unwrapped(t).to_html(options: OPTIONS, plugins: { syntax_highlighter: nil }).inspect
end

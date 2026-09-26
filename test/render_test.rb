# Rendering under lobsters' options and under explicit ones: raw HTML
# escaped (the option cmark-gfm lacks), the GFM extensions, code blocks
# (github_pre_lang), hard breaks, unsafe, and the node types a walk sees.
require "commonmarker"

OPTS = {
  extension: { tagfilter: true, autolink: true, strikethrough: true, header_ids: nil, shortcodes: nil },
  render: { escape: true, hardbreaks: false, escaped_char_spans: false },
}
UNSAFE = {
  extension: { header_ids: nil, shortcodes: nil },
  render: { unsafe: true, escaped_char_spans: false },
}

INPUTS = [
  "a <a href=\"x&y\" title='q'>l</a> b",
  "<div class=\"c\">\n</div>",
  "x <!-- raw HTML omitted --> y",
  "<b>one</b><i>two</i>",
  "[j](javascript:alert(1))",
  "```ruby\nx = 1\n```\n\n    indented\n",
  "line1  \nline2\nline3",
  "- [ ] todo\n- [x] done",
  "|a|b|\n|-|-|\n|1|2|",
  "~one~ ~~two~~",
  "&copy; &#65; \\*lit\\*",
  "<script>alert(1)</script>\n\n<p>ok</p>",
]

INPUTS.each do |t|
  puts "== #{t.inspect}"
  puts Commonmarker.to_html(t, options: OPTS, plugins: { syntax_highlighter: nil }).inspect
  puts Commonmarker.to_html(t, options: UNSAFE, plugins: { syntax_highlighter: nil }).inspect
end

doc = Commonmarker.parse("# T\n\npara *e* **s** `c` [l](u) ![i](p)\n\n- a\n\n> q", options: OPTS)
types = []
doc.walk { |n| types << n.type }
puts types.inspect

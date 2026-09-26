# NOT a conformance test (kept out of test/, which `spin test` gates):
# `to_commonmark` is this package's one known divergence from the
# gem. comrak writes CommonMark with its own renderer (cm.rs) and this
# package uses cmark-gfm's, and they differ in which characters get a
# backslash (`\@` vs `\~`), whether a soft break survives at width 80,
# and list-marker spacing (`- a` / `1. a` vs `  - a` / `1.  a`). The
# README has the list. `divergence/commonmark.rb.gem` is the gem's output for
# the same script, so the gap stays visible.
require "commonmarker"

OPTIONS = {
  extension: { tagfilter: true, autolink: true, strikethrough: true, header_ids: nil, shortcodes: nil },
  render: { escape: true, hardbreaks: false, escaped_char_spans: false },
}

[
  "Hello @alice, see ~bob's post.",
  "A paragraph.\n\nAnother with @carol\nand a soft break.",
  "- one *a*\n- two **b**\n\n1. first\n2. second",
  "`code` and *emph* and [link](http://x.test)",
  "plain text only",
].each do |t|
  puts Commonmarker.parse(t, options: OPTIONS).to_commonmark.inspect
end

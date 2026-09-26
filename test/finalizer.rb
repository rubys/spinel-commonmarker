# The owners, observed. Not a conformance test -- the gem has no count to
# compare -- so it is named without `_test` and the oracle (which runs
# test/*_test.rb under CRuby) leaves it alone; `spin test` runs it.
#
# Every parse and every Node.new makes an owner, and only the GC gives one
# back (sp_cmark.c). The loop does what Markdowner does to a tree —
# makes nodes, inserts them (merging their owners into the document's),
# deletes nodes mid-walk (detached pieces the owner must free) — two
# thousand times. If the owners were never released, all of them would
# still be counted; if a piece were freed twice or too early, this would
# crash rather than print.
require "commonmarker"

OPTIONS = {
  extension: { tagfilter: true, autolink: true, strikethrough: true, header_ids: nil, shortcodes: nil },
  render: { escape: true, hardbreaks: false, escaped_char_spans: false },
}

made = 0
bytes = 0
2000.times do |i|
  root = Commonmarker.parse("hello *there* @u#{i} [l](http://x) **b**", options: OPTIONS)
  made += 1
  para = root.first_child
  link = Commonmarker::Node.new(:link, url: "http://u/#{i}")
  text = Commonmarker::Node.new(:text)
  text.string_content = "@u#{i}"
  link.append_child(text)
  para.append_child(link)
  made += 2
  root.walk do |n|
    if n.type == :emph || n.type == :strong
      n.insert_before(n.first_child)
      n.delete
    end
  end
  orphan = Commonmarker::Node.new(:text)
  orphan.string_content = "never inserted"
  made += 1
  bytes += root.to_html(options: OPTIONS, plugins: { syntax_highlighter: nil }).length
end
GC.start
live = CommonmarkerExt.sp_cmark_live_owners
puts "made: #{made}"
puts "rendered: #{bytes > 0}"
puts "released after GC: #{live < made / 2}"

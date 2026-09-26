# Conformance over three corpora, every record rendered two ways: under
# lobsters' Markdowner options (raw HTML escaped) and with `unsafe: true`.
#
#   corpus/commonmark_spec.txt   the 652 CommonMark 0.31.2 spec examples
#                                (spec.commonmark.org, CC BY-SA 4.0)
#   corpus/gfm_spec.txt          the 672 examples in cmark-gfm's GFM spec
#                                (test/spec.txt, CC BY-SA 4.0)
#   corpus/lobsters_fake_data.txt  400 comments, bios and descriptions from
#                                lobsters' fake-data generator
#
# Records are separated by "\x1e\n". Every line is the gem's answer
# (`sh oracle/run.sh`), except the records in KNOWN: the 22 spec examples
# where cmark-gfm itself differs from comrak (README, "Divergences"). Those
# print a marker instead, identically on both sides, so the gate holds on
# everything else and the list stays in one visible place.
require "commonmarker"

LOBSTERS = {
  extension: { tagfilter: true, autolink: true, strikethrough: true, header_ids: nil, shortcodes: nil },
  render: { escape: true, hardbreaks: false, escaped_char_spans: false },
}
UNSAFE = {
  extension: { header_ids: nil, shortcodes: nil },
  render: { unsafe: true, hardbreaks: false, escaped_char_spans: false },
}
PLUGINS = { syntax_highlighter: nil }

KNOWN = {
  # nested <strong> collapsed (cmark-gfm's HTML renderer), 0.29 vs 0.31
  # character references and currency punctuation, and cmark-gfm's email
  # autolink of a backslash-escaped address — see README.
  "commonmark_spec" => [27, 353, 388, 416, 424, 425, 426, 463, 464, 465, 467, 605],
  "gfm_spec" => [397, 425, 433, 434, 435, 472, 473, 474, 476, 613],
  "lobsters_fake_data" => [],
}

%w[commonmark_spec gfm_spec lobsters_fake_data].each do |name|
  records = File.read(File.join(File.dirname(__FILE__), "corpus", "#{name}.txt")).split("\x1e\n", -1)
  records.each_with_index do |md, i|
    puts "#{name} #{i}"
    if KNOWN[name].include?(i)
      puts "known divergence (see README)"
      next
    end
    puts Commonmarker.to_html(md, options: LOBSTERS, plugins: PLUGINS).inspect
    puts Commonmarker.to_html(md, options: UNSAFE, plugins: PLUGINS).inspect
  end
end

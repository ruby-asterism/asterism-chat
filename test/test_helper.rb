require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/chat"
require "zlib"
require "digest"

# Small PNG files for the stamp tests, built here (no image library).
module TestPng
  module_function

  def chunk(type, data)
    body = type.b + data.b
    [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
  end

  # A w x h picture: palette at 8 bits by default, every pixel the colour
  # `seed` (and the seed in a text chunk, so different seeds give
  # different files). pad: bytes of an
  # ancillary chunk to make the file bigger.
  def make(w, h, seed: 0, ctype: 3, depth: 8, interlace: 0, pad: 0)
    channels = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }.fetch(ctype)
    row = "\x00".b + ([seed % 256] * ((w * depth * channels + 7) / 8)).pack("C*")
    out = "\x89PNG\r\n\x1a\n".b
    out << chunk("IHDR", [w, h, depth, ctype, 0, 0, interlace].pack("NNCCCCC"))
    out << chunk("PLTE", ([seed % 256, 0, 0] * 256).pack("C*")) if ctype == 3
    out << chunk("tEXt", "Seed\x00#{seed}".b)
    out << chunk("tEXt", "Comment\x00".b + ("x" * pad).b) if pad.positive?
    out << chunk("IDAT", Zlib::Deflate.deflate(row * h))
    out << chunk("IEND", "")
    out
  end

  def sha(bytes) = Digest::SHA256.hexdigest(bytes)
end

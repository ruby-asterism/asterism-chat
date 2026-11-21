require "zlib"

module Chat
  # Checks a stamp's PNG without decoding it: the signature, the first
  # chunk (IHDR, with its CRC), the size, the colour type and bit depth and
  # no interlace. The kinds accepted are the ones the devices decode
  # (fmruby-core lib/gems/picoruby-fmrb-bmp332, png332.c): grey and palette
  # at 1, 2, 4 or 8 bits, RGB, grey+alpha and RGBA at 8 bits.
  module Png
    SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    # colour type => the bit depths accepted
    DEPTHS = { 0 => [1, 2, 4, 8], 2 => [8], 3 => [1, 2, 4, 8], 4 => [8], 6 => [8] }.freeze

    class Bad < StandardError; end

    # [width, height], or raises Bad (why, in English, for the record).
    def self.size(bytes)
      b = bytes.b
      raise Bad, "not a PNG (signature)" unless b.start_with?(SIGNATURE)
      raise Bad, "too short for an IHDR" if b.bytesize < 8 + 8 + 13 + 4
      len, type = b.byteslice(8, 8).unpack("Na4")
      raise Bad, "the first chunk is not IHDR" unless type == "IHDR" && len == 13
      body = b.byteslice(16, 13)
      crc = b.byteslice(29, 4).unpack1("N")
      raise Bad, "IHDR CRC does not match" unless Zlib.crc32("IHDR".b + body) == crc
      w, h, depth, ctype, comp, filter, interlace = body.unpack("NNCCCCC")
      raise Bad, "width or height is 0" if w.zero? || h.zero?
      raise Bad, "colour type #{ctype} at #{depth} bits" unless DEPTHS.fetch(ctype, []).include?(depth)
      raise Bad, "compression #{comp} or filter #{filter}" unless comp.zero? && filter.zero?
      raise Bad, "interlaced" unless interlace.zero?
      [w, h]
    end
  end
end

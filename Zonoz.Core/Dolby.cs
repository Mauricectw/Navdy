using System.Text;

namespace Zonoz.Core;

/// <summary>
/// 判斷 MP4 容器裡的 E-AC-3 是否帶 Dolby Atmos（JOC）擴充（ETSI TS 103 420）：
/// dec3 在各子串流描述之後若還有位元組，flag_ec3_extension_type_a = 1 即代表 E-AC-3 JOC。
/// 只用來在曲庫顯示徽章，不影響推流行為。
/// </summary>
public static class Dolby
{
    public sealed record Ec3Info(bool IsJoc, int ComplexityIndex);

    /// <summary>payload 是 dec3 box 去掉 8 位元組 box 頭之後的內容。</summary>
    public static Ec3Info? ParseDec3(byte[] payload)
    {
        var reader = new BitReader(payload);
        if (reader.Read(13) is null || reader.Read(3) is not int numIndSubMinus1) return null;
        for (var i = 0; i <= numIndSubMinus1; i++)
        {
            // fscod 2, bsid 5, reserved 1, asvc 1, bsmod 3, acmod 3, lfeon 1, reserved 3
            if (reader.Read(19) is null || reader.Read(4) is not int numDepSub) return null;
            if (reader.Read(numDepSub > 0 ? 9 : 1) is null) return null;
        }
        if (reader.BitsRemaining >= 16 && reader.Read(7) is not null && reader.Read(1) is int flag && reader.Read(8) is int complexity)
            return new Ec3Info(flag == 1, complexity);
        return new Ec3Info(false, 0);
    }

    /// <summary>在一段 moov 資料裡找第一個 dec3 box，回傳其內容。</summary>
    public static byte[]? FindDec3(byte[] moov)
    {
        var n = moov.Length;
        for (var i = 4; i + 4 <= n; i++)
        {
            if (moov[i] != 0x64 || moov[i + 1] != 0x65 || moov[i + 2] != 0x63 || moov[i + 3] != 0x33) continue;
            var size = (moov[i - 4] << 24) | (moov[i - 3] << 16) | (moov[i - 2] << 8) | moov[i - 1];
            if (size >= 10 && size <= 64 && i - 4 + size <= n) return moov.AsSpan(i + 4, size - 8).ToArray();
        }
        return null;
    }

    private struct BitReader
    {
        private readonly byte[] _bytes;
        private int _position;
        public BitReader(byte[] bytes) { _bytes = bytes; _position = 0; }
        public int BitsRemaining => _bytes.Length * 8 - _position;

        public int? Read(int count)
        {
            if (count <= 0 || count > 32 || BitsRemaining < count) return null;
            var value = 0;
            for (var i = 0; i < count; i++)
            {
                var bit = (_bytes[_position / 8] >> (7 - _position % 8)) & 1;
                value = (value << 1) | bit;
                _position++;
            }
            return value;
        }
    }
}

/// <summary>讀 MP4 / M4A 的 moov：取得音訊編碼（stsd 的 sample entry 類型）與是否為 Atmos。</summary>
public static class Mp4Info
{
    public sealed record Result(string Codec, bool IsAtmos);

    public static Result? Probe(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var fileSize = stream.Length;
            long offset = 0;
            var header = new byte[16];
            for (var guard = 0; guard < 64 && offset + 8 <= fileSize; guard++)
            {
                stream.Position = offset;
                var read = stream.Read(header, 0, 16);
                if (read < 8) return null;
                long size = ((long)header[0] << 24) | ((long)header[1] << 16) | ((long)header[2] << 8) | header[3];
                var type = Encoding.ASCII.GetString(header, 4, 4);
                long headerSize = 8;
                if (size == 1)
                {
                    if (read < 16) return null;
                    size = 0;
                    for (var i = 8; i < 16; i++) size = (size << 8) | header[i];
                    headerSize = 16;
                }
                else if (size == 0) size = fileSize - offset;
                if (size < headerSize) return null;

                if (type == "moov")
                {
                    var bodySize = size - headerSize;
                    if (bodySize <= 0 || bodySize > 32 * 1024 * 1024) return null;
                    var body = new byte[bodySize];
                    stream.Position = offset + headerSize;
                    stream.ReadExactly(body, 0, body.Length);
                    return FromMoov(body);
                }
                offset += size;
            }
        }
        catch
        {
            // 讀不了就當不知道
        }
        return null;
    }

    public static Result FromMoov(byte[] moov)
    {
        var codec = "";
        // stsd：'stsd'(4) version/flags(4) entry_count(4) 然後第一個 entry：size(4) type(4)
        for (var i = 0; i + 20 <= moov.Length; i++)
        {
            if (moov[i] == 0x73 && moov[i + 1] == 0x74 && moov[i + 2] == 0x73 && moov[i + 3] == 0x64)
            {
                codec = Encoding.ASCII.GetString(moov, i + 16, 4).Trim();
                break;
            }
        }
        var atmos = false;
        if (codec == "ec-3")
        {
            var dec3 = Dolby.FindDec3(moov);
            atmos = dec3 != null && (Dolby.ParseDec3(dec3)?.IsJoc ?? false);
        }
        return new Result(codec, atmos);
    }
}

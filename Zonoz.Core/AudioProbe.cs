using System.Text;

namespace Zonoz.Core;

/// <summary>
/// 讀取本地音訊檔的真實取樣率 / 位元深度。Sonos 本地音樂封頂 48 kHz；WAV / AIFF 只支援 16 bit。
/// 超規格的檔案不會報錯，而是「拉一段資料後自己跳過」，看起來像 App 的 bug。
/// </summary>
public static class AudioProbe
{
    public sealed record Format(string Codec, int SampleRate, int Bits);

    /// <summary>只需要檔頭前 64 位元組；認不出就回 null（放行）</summary>
    public static Format? Probe(byte[] b) => b.Length < 42 ? null : ParseFlac(b) ?? ParseWav(b) ?? ParseAiff(b);

    public static Format? ProbeFile(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var buffer = new byte[64];
            var read = stream.Read(buffer, 0, buffer.Length);
            return Probe(read == buffer.Length ? buffer : buffer.AsSpan(0, read).ToArray());
        }
        catch
        {
            return null;
        }
    }

    private static int Be32(byte[] b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    private static int Le32(byte[] b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
    private static int Le16(byte[] b, int o) => b[o] | (b[o + 1] << 8);
    private static string Tag(byte[] b, int o) => Encoding.ASCII.GetString(b, o, 4);

    /// <summary>fLaC + STREAMINFO：取樣率 20 bit、位元深度 5 bit</summary>
    private static Format? ParseFlac(byte[] b)
    {
        if (b.Length < 42 || Tag(b, 0) != "fLaC") return null;
        const int p = 8;
        var rate = (b[p + 10] << 12) | (b[p + 11] << 4) | (b[p + 12] >> 4);
        var bits = (((b[p + 12] & 0x01) << 4) | ((b[p + 13] & 0xF0) >> 4)) + 1;
        return rate <= 0 ? null : new Format("FLAC", rate, bits);
    }

    private static Format? ParseWav(byte[] b)
    {
        var n = b.Length;
        if (n < 36 || Tag(b, 0) != "RIFF") return null;
        var o = 12;
        while (o + 8 <= n)
        {
            var id = Tag(b, o);
            var size = Le32(b, o + 4);
            var data = o + 8;
            if (id == "fmt " && data + 16 <= n)
            {
                var rate = Le32(b, data + 4);
                var bits = Le16(b, data + 14);
                return rate > 0 ? new Format("WAV", rate, bits) : null;
            }
            if (size <= 0) break;
            o = data + size + (size & 1);
        }
        return null;
    }

    /// <summary>FORM/AIFF + COMM 區塊（取樣率是 80-bit extended）</summary>
    private static Format? ParseAiff(byte[] b)
    {
        var n = b.Length;
        if (n < 40 || Tag(b, 0) != "FORM") return null;
        var o = 12;
        while (o + 8 <= n)
        {
            var id = Tag(b, o);
            var size = Be32(b, o + 4);
            var data = o + 8;
            if (id == "COMM" && data + 18 <= n)
            {
                var bits = (b[data + 6] << 8) | b[data + 7];
                var exp = ((b[data + 8] & 0x7F) << 8) | b[data + 9];
                ulong mantissa = 0;
                for (var i = 0; i < 8; i++) mantissa = (mantissa << 8) | b[data + 10 + i];
                var rate = 0;
                if (exp != 0 && mantissa != 0)
                {
                    var value = mantissa * Math.Pow(2.0, exp - 16383 - 63);
                    if (double.IsFinite(value) && value > 0 && value < 10_000_000) rate = (int)value;
                }
                return rate > 0 ? new Format("AIFF", rate, bits) : null;
            }
            if (size <= 0) break;
            o = data + size + (size & 1);
        }
        return null;
    }

    /// <summary>超出 Sonos 規格：>48 kHz；WAV/AIFF 超過 16 bit</summary>
    public static bool IsUnsupported(Format? f)
    {
        if (f == null) return false;
        if (f.SampleRate > 48000) return true;
        return f.Codec is "WAV" or "AIFF" ? f.Bits > 16 : f.Bits > 24;
    }

    /// <summary>例如 "FLAC 96 kHz / 24 bit"</summary>
    public static string Describe(Format f)
    {
        string khz;
        if (f.SampleRate % 1000 == 0) khz = $"{f.SampleRate / 1000} kHz";
        else
        {
            var tenths = (f.SampleRate + 50) / 100;
            khz = $"{tenths / 10}.{tenths % 10} kHz";
        }
        return $"{f.Codec} {khz} / {f.Bits} bit";
    }
}

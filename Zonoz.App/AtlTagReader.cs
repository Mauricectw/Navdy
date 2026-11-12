using Zonoz.Core;

namespace Zonoz.App;

/// <summary>用 Audio Tools Library 讀標籤、時長與內嵌封面。</summary>
public sealed class AtlTagReader : ITagReader
{
    public TagInfo? Read(string path)
    {
        var t = new ATL.Track(path);
        return new TagInfo(
            t.Title ?? "",
            t.Artist ?? "",
            t.Album ?? "",
            (int)Math.Max(0, t.DurationMs),
            (int)Math.Max(0, t.SampleRate),
            t.ChannelsArrangement?.NbChannels ?? 0);
    }

    public byte[]? ReadCover(string path)
    {
        try
        {
            var t = new ATL.Track(path);
            var pictures = t.EmbeddedPictures;
            return pictures != null && pictures.Count > 0 ? pictures[0].PictureData : null;
        }
        catch
        {
            return null;
        }
    }
}

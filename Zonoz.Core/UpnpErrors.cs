namespace Zonoz.Core;

public enum UpnpErrorKind { Reach, Format, BadRequest, Offline, Satellite, Unknown }

/// <summary>UPnP / Sonos 錯誤碼。數字碼只留在日誌，給使用者看的文案在 UI 層。</summary>
public static class UpnpErrors
{
    public const int SatelliteCode = 1023;

    public static UpnpErrorKind Kind(int? code) => code switch
    {
        null => UpnpErrorKind.Offline,
        701 or 702 or 716 => UpnpErrorKind.Reach,
        714 => UpnpErrorKind.Format,
        402 => UpnpErrorKind.BadRequest,
        800 => UpnpErrorKind.Offline,
        1023 => UpnpErrorKind.Satellite,
        _ => UpnpErrorKind.Unknown,
    };

    public static string Describe(int? code) => code switch
    {
        null => "no UPnP error code",
        401 => "Invalid Action", 402 => "Invalid Args", 501 => "Action Failed",
        701 => "Transition not available", 702 => "No contents", 704 => "Invalid connection reference",
        705 => "Transport is locked", 710 => "Seek mode not supported", 711 => "Illegal seek target",
        712 => "Play speed not supported", 714 => "Illegal MIME-Type", 715 => "Content busy",
        716 => "Resource not found", 718 => "Invalid InstanceID", 800 => "Unable to connect",
        1023 => "Satellite unit (Sonos private)",
        _ => $"UPnP {code}",
    };
}

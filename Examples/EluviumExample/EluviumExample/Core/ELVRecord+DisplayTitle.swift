import EluviumCore

extension ELVRecord {
    /// The record's display name, nil when it carries none: its `label`
    /// (one name ranked across the page, the share text, the URL, and the
    /// brand, for sources with a label ladder), else its `title`. Every
    /// title surface (navigation bars, rows, the Now Playing readout) reads
    /// this one accessor instead of re-spelling the field lookup.
    var displayTitle: String? {
        (fields["label"] ?? fields["title"]).map(ELVValueDisplay.string)
    }
}

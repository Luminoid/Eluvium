import EluviumCore

extension ELVRecord {
    /// The record's `title` field rendered for display, nil when the record
    /// carries none. Every title surface (navigation bars, rows, the Now
    /// Playing readout) reads this one accessor instead of re-spelling the
    /// `fields["title"].map(ELVValueDisplay.string)` lookup.
    var displayTitle: String? {
        fields["title"].map(ELVValueDisplay.string)
    }
}

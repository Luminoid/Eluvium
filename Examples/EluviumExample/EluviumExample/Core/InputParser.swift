import EluviumCore

/// Reads the paste box through the framework's pasted-text input. The box
/// takes only links, so it composes both readings: the strict one first
/// (a share blurb's embedded link with its leading text, an app link the
/// pack claims), then the lenient one for a bare host the strict TLD list
/// doesn't know ("pokeapi.co/api/v2/pokemon/25" gains `https://`). A token
/// with a scheme the strict reading turned down stays turned down.
enum InputParser {
    static func input(in text: String, policy: ELVPastePolicy) -> ELVPastedInput? {
        if let input = ELVPastedInput.parse(text, policy: policy) { return input }
        guard !text.contains("://") else { return nil }
        return ELVPastedInput.link(text, policy: policy)
    }
}

import Foundation

func splitShellLike(_ input: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?

    for character in input {
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            } else {
                current.append(character)
            }
        } else if character.isWhitespace && quote == nil {
            if !current.isEmpty {
                result.append(current)
                current.removeAll()
            }
        } else {
            current.append(character)
        }
    }

    if !current.isEmpty {
        result.append(current)
    }
    return result
}

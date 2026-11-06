// Default build secrets (empty). GitHub Actions overwrites this file at build
// time from the GEMINI_API_KEY repository secret. Never commit a real key.
enum BuildSecrets {
    static let geminiDefaultKey: String = ""
}

import spacy

# Load Spacy English model
nlp = spacy.load("en_core_web_sm")


def analyze_text(file_path):
    with open(file_path, "r", encoding="utf-8") as file:
        text = file.read()

    doc = nlp(text)
    sentences = list(doc.sents)

    # Detect gerund phrases preceded by a possessive determiner
    possessive_gerund_sentences = []
    gerund_count = 0
    total_gerund_phrases = 0

    for sent in sentences:
        for token in sent:
            if token.tag_ == "VBG":  # Gerund verb form
                total_gerund_phrases += 1
                if token.i > 0 and doc[token.i - 1].tag_ in ["PRP$"]:  # Possessive determiner
                    possessive_gerund_sentences.append(sent.text)
                    gerund_count += 1

    gerund_percentage = (gerund_count / total_gerund_phrases * 100) if total_gerund_phrases else 0

    # Output results
    results = {
        "Gerund Phrases with Possessive Determiners": {
            "Sentences": possessive_gerund_sentences,
            "Total Gerund Phrases": total_gerund_phrases,
            "Total Gerunds with Possessive Determiners": gerund_count,
            "Percentage": gerund_percentage
        }
    }

    return results


# Example usage
file_path = "/Users/kyliebushey/Desktop/True Crime Research/Zodiac 2025/Map 2025/COE Project/COE.txt"  # <-- Replace this with the actual file path
analysis_results = analyze_text(file_path)

# Print results
print("\nGerund Analysis Results:")
print(f"Total Gerund Phrases: {analysis_results['Gerund Phrases with Possessive Determiners']['Total Gerund Phrases']}")
print(
    f"Total Gerunds with Possessive Determiners: {analysis_results['Gerund Phrases with Possessive Determiners']['Total Gerunds with Possessive Determiners']}")
print(f"Percentage: {analysis_results['Gerund Phrases with Possessive Determiners']['Percentage']:.2f}%")

print("\nSentences with Possessive Determiner + Gerund:")
for sentence in analysis_results["Gerund Phrases with Possessive Determiners"]["Sentences"]:
    print(sentence)

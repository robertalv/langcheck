import spacy

# Load Spacy English model
nlp = spacy.load("en_core_web_sm")


def analyze_gerunds(file_path):
    with open(file_path, "r", encoding="utf-8") as file:
        lines = file.readlines()

    # Remove lines starting with common letter closings and greetings, and remove specific names
    cleaned_lines = []
    for line in lines:
        stripped_line = line.strip()
        if any(stripped_line.lower().startswith(phrase) for phrase in
               ["dear ", "sincerely", "very sincerely", "all best wishes", "cordially", "my dear "]):
            continue
        if stripped_line.lower() == "derek":
            continue
        if stripped_line:  # Remove empty lines
            cleaned_lines.append(stripped_line)

    cleaned_text = "\n".join(cleaned_lines)

    doc = nlp(cleaned_text)
    sentences = list(doc.sents)

    total_gerunds = 0
    in_gerund_count = 0
    in_gerund_sentences = []

    for sent in sentences:
        tokens = list(sent)
        for i, token in enumerate(tokens):
            if token.tag_ == "VBG":  # Gerund verb form
                total_gerunds += 1
                if i > 0 and tokens[i - 1].text.lower() == "in":
                    in_gerund_count += 1
                    in_gerund_sentences.append(sent.text)

    in_gerund_percentage = (in_gerund_count / total_gerunds * 100) if total_gerunds else 0

    # Output results
    results = {
        "Total Gerund Phrases": total_gerunds,
        "Total In Followed by Gerund": in_gerund_count,
        "Percentage of In Before Gerund": in_gerund_percentage,
        "Sentences with In Before Gerund": in_gerund_sentences
    }

    return results


# Example usage
file_path = ("/Users/kyliebushey/Desktop/True Crime Research/Zodiac 2025/Map 2025/COE Project/COE.txt") # Allow compatibility with other TXT files

analysis_results = analyze_gerunds(file_path)

# Print results
print("\nGerund Analysis Results:")
print(f"Total Gerund Phrases: {analysis_results['Total Gerund Phrases']}")
print(f"Total In Followed by Gerund: {analysis_results['Total In Followed by Gerund']}")
print(f"Percentage of In Before Gerund: {analysis_results['Percentage of In Before Gerund']:.2f}%")

print("\nSentences with In Before Gerund:")
for sentence in analysis_results["Sentences with In Before Gerund"]:
    print(sentence)
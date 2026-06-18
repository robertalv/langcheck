import re
from collections import Counter

def normalize_text(text):
    """ Normalize apostrophes to standard single quote."""
    return text.replace("’", "'").replace("‘", "'")

def analyze_text(file_path):
    contractions = [
        "'bout", "'cause", "'em", "'round", "'til", "'tis", "ain't", "aren't", "c'mon", "can't",
        "could've", "couldn't", "cuz", "didn't", "doesn't", "don't", "dunno", "everybody's", "everyone's",
        "everything's", "gimme", "gonna", "gotta", "hadn't", "hasn't", "haven't", "he'd", "he'll", "he's",
        "here's", "how'd", "how're", "how's", "I'd", "I'll", "I'm", "I've", "isn't", "it'd", "it'll",
        "it's", "kinda", "lemme", "let's", "mightn't", "needn't", "no one's", "nothing's", "shan't",
        "she'd", "she'll", "she's", "should've", "shouldn't", "somebody's", "someone's", "something's",
        "that'd", "that'll", "that're", "that's", "there'd", "there'll", "there're", "there's", "they'd",
        "they'll", "they're", "they've", "wanna", "wasn't", "we'd", "we'll", "we're", "we've", "weren't",
        "what'd", "what'll", "what's", "what've", "whatcha", "when'd", "when's", "where'd", "where'll",
        "where're", "where's", "which's", "which've", "who'd", "who'll", "who're", "who's", "who've",
        "why'd", "why're", "why's", "won't", "would've", "wouldn't", "y'all"
    ]
    contractions = sorted([c.lower() for c in contractions], key=len, reverse=True)  # Sort longest first

    non_contractions = [
        "about", "am not", "are not", "around", "because", "can not", "cannot", "come on", "could have",
    "could not", "did not", "do not", "do not know", "does not", "don't know", "everybody has",
    "everybody is", "everyone has", "everyone is", "everything has", "everything is", "give me",
    "going to", "got to", "had not", "has not", "have not", "he had", "he has", "he is", "he shall",
    "he will", "he would", "here is", "how are", "how did", "how has", "how is", "how would", "I am",
    "I had", "I have", "I shall", "I will", "I would", "is not", "it has", "it is", "it shall",
    "it will", "it would", "kind of", "let me", "let us", "might not", "need not", "no one has",
    "no one is", "nothing has", "nothing is", "shall not", "she had", "she has", "she is", "she shall",
    "she will", "she would", "should have", "should not", "somebody has", "somebody is", "someone has",
    "someone is", "something has", "something is", "that are", "that had", "that has", "that is",
    "that shall", "that will", "that would", "there are", "there had", "there has", "there is",
    "there shall", "there will", "there would", "they are", "they had", "they have", "they shall",
    "they will", "they would", "until", "want to", "was not", "we are", "we had", "we have", "we shall",
    "we will", "we would", "were not", "what are you", "what did", "what does", "what has", "what have",
    "what is", "what shall", "what will", "when did", "when does", "when has", "when is", "where are",
    "where did", "where does", "where has", "where is", "where shall", "where will", "which has",
    "which have", "which is", "who are", "who did", "who does", "who had", "who has", "who have",
    "who is", "who shall", "who will", "who would", "why are", "why did", "why does", "why has",
    "why is", "will not", "would have", "would not", "you all"
    ]
    non_contractions = [nc.lower() for nc in non_contractions]  # Convert all to lowercase

    contraction_count = Counter()
    non_contracted_count = Counter()

    with open(file_path, 'r', encoding='utf-8') as file:
        text = file.read().lower()
        text = normalize_text(text)

    for contraction in contractions:
        contraction_count[contraction] = len(re.findall(rf"(?<!\w){re.escape(contraction)}(?!\w)", text))

    for non_contraction in non_contractions:
        non_contracted_count[non_contraction] = len(re.findall(rf"(?<!\w){re.escape(non_contraction)}(?!\w)", text))

    total_contracted = sum(contraction_count.values())
    total_non_contracted = sum(non_contracted_count.values())
    total_words = total_contracted + total_non_contracted
    contraction_percentage = (total_contracted / total_words * 100) if total_words > 0 else 0

    print(f"Number of contracted words: {total_contracted}")
    print(f"Number of non-contracted words: {total_non_contracted}")
    print(f"Percentage of contractions used: {contraction_percentage:.2f}%")

    print("\nDetailed Contraction Counts (Most to Least Common):")
    for contraction, count in sorted(contraction_count.items(), key=lambda item: item[1], reverse=True):
        if count > 0:
            print(f"{contraction}: {count}")

    print("\nDetailed Non-Contraction Counts (Most to Least Common):")
    for non_contraction, count in sorted(non_contracted_count.items(), key=lambda item: item[1], reverse=True):
        if count > 0:
            print(f"{non_contraction}: {count}")

    return contraction_count, non_contracted_count, contraction_percentage

if __name__ == "__main__":
    file_path = "/Users/kyliebushey/Desktop/PriceLecture6.txt"
    analyze_text(file_path)
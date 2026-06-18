import re

def count_words(text, word):
    """Counts occurrences of a word in a text, case insensitive."""
    return len(re.findall(rf'\b{word}\b', text, re.IGNORECASE))

def analyze_text(file_path):
    """Analyzes the text for occurrences of 'will' and 'shall'."""
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            text = file.read()

        will_count = count_words(text, 'will')
        shall_count = count_words(text, 'shall')
        total = will_count + shall_count
        shall_percentage = (shall_count / total * 100) if total > 0 else 0

        print(f"Occurrences of 'will': {will_count}")
        print(f"Occurrences of 'shall': {shall_count}")
        print(f"Percentage of 'shall' usage: {shall_percentage:.2f}%")
    except FileNotFoundError:
        print("Error: File not found.")
    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    file_path = "/Users/kyliebushey/Desktop/Price Stuff/TXTs/TXT Files/Price Corpus/Price_All_NEW_21,090 Words.txt"  # Replace with your file path
    analyze_text(file_path)
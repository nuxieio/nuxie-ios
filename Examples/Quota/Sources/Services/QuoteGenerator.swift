//
//  QuoteGenerator.swift
//  Quota
//
//  Simulated AI quote generation.
//

import Foundation

struct QuoteGenerator {
    static let quotes: [(text: String, author: String)] = [
        ("The only way to do great work is to love what you do.", "Steve Jobs"),
        ("In the middle of difficulty lies opportunity.", "Albert Einstein"),
        ("The future belongs to those who believe in the beauty of their dreams.", "Eleanor Roosevelt"),
        ("It is during our darkest moments that we must focus to see the light.", "Aristotle"),
        ("The best time to plant a tree was 20 years ago. The second best time is now.", "Chinese Proverb"),
        ("Success is not final, failure is not fatal: it is the courage to continue that counts.", "Winston Churchill"),
        ("The only impossible journey is the one you never begin.", "Tony Robbins"),
        ("Believe you can and you're halfway there.", "Theodore Roosevelt"),
        ("The way to get started is to quit talking and begin doing.", "Walt Disney"),
        ("Don't watch the clock; do what it does. Keep going.", "Sam Levenson"),
        ("Everything you've ever wanted is on the other side of fear.", "George Addair"),
        ("Success usually comes to those who are too busy to be looking for it.", "Henry David Thoreau"),
        ("Don't be afraid to give up the good to go for the great.", "John D. Rockefeller"),
        ("I find that the harder I work, the more luck I seem to have.", "Thomas Jefferson"),
        ("The mind is everything. What you think you become.", "Buddha"),
        ("Strive not to be a success, but rather to be of value.", "Albert Einstein"),
        ("The only limit to our realization of tomorrow is our doubts of today.", "Franklin D. Roosevelt"),
        ("What you get by achieving your goals is not as important as what you become.", "Zig Ziglar"),
        ("The secret of getting ahead is getting started.", "Mark Twain"),
        ("Quality is not an act, it is a habit.", "Aristotle")
    ]

    static func random() -> Quote {
        let randomQuote = quotes.randomElement() ?? quotes[0]
        return Quote(text: randomQuote.text, author: randomQuote.author)
    }
}

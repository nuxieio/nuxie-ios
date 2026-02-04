//
//  ShopItem.swift
//  Coinverse
//
//  Model for a purchasable item in the shop.
//

import Foundation

struct ShopItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let cost: Int
    let category: Category
    let description: String

    enum Category: String, Codable, CaseIterable {
        case sticker = "Stickers"
        case theme = "Themes"
        case avatar = "Avatars"
        case effect = "Effects"
    }

    static let all: [ShopItem] = [
        // Stickers
        ShopItem(id: "sticker_star", name: "Star", emoji: "⭐", cost: 5, category: .sticker, description: "A classic golden star sticker"),
        ShopItem(id: "sticker_fire", name: "Fire", emoji: "🔥", cost: 10, category: .sticker, description: "Blazing hot fire sticker"),
        ShopItem(id: "sticker_moon", name: "Moon", emoji: "🌙", cost: 15, category: .sticker, description: "Mystical crescent moon"),
        ShopItem(id: "sticker_rocket", name: "Rocket", emoji: "🚀", cost: 20, category: .sticker, description: "To the moon! Rocket sticker"),

        // Themes
        ShopItem(id: "theme_robot", name: "Robot", emoji: "🤖", cost: 25, category: .theme, description: "Futuristic robot theme"),
        ShopItem(id: "theme_art", name: "Artist", emoji: "🎨", cost: 30, category: .theme, description: "Creative artistic theme"),
        ShopItem(id: "theme_galaxy", name: "Galaxy", emoji: "🌌", cost: 40, category: .theme, description: "Cosmic galaxy theme"),

        // Avatars
        ShopItem(id: "avatar_sparkle", name: "Sparkle", emoji: "✨", cost: 35, category: .avatar, description: "Sparkling avatar frame"),
        ShopItem(id: "avatar_crown", name: "Crown", emoji: "👑", cost: 50, category: .avatar, description: "Royal crown avatar"),
        ShopItem(id: "avatar_diamond", name: "Diamond", emoji: "💎", cost: 75, category: .avatar, description: "Premium diamond avatar"),

        // Effects
        ShopItem(id: "effect_rainbow", name: "Rainbow", emoji: "🌈", cost: 45, category: .effect, description: "Rainbow effect overlay"),
        ShopItem(id: "effect_confetti", name: "Confetti", emoji: "🎉", cost: 55, category: .effect, description: "Celebration confetti effect")
    ]

    static func item(for id: String) -> ShopItem? {
        all.first { $0.id == id }
    }
}

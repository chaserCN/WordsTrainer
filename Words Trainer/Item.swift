//
//  Item.swift
//  Words Trainer
//
//  Created by Nikolay on 28.05.2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

//
//  Concurrency.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 13.12.23.
//

import Foundation

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension Sequence {
    
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values = [T]()
        
        for element in self {
            try await values.append(transform(element))
        }
        
        return values
    }
    
    func concurrentMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async -> T) async -> [T] where Element: Sendable {
        
        let items = Array(self)
        return await withTaskGroup(of: (Int, T).self, returning: [T].self) { group in
            for (index, element) in items.enumerated() {
                group.addTask { (index, await transform(element)) }
            }
            var results: [(Int, T)] = []
            for await value in group { results.append(value) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

    }
    
}

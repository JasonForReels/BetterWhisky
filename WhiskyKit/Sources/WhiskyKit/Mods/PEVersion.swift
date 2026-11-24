//
//  PEVersion.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

/// A Windows file version: four numbers, compared in order.
public struct PEVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var build: Int
    public var revision: Int

    public init(_ major: Int, _ minor: Int, _ build: Int = 0, _ revision: Int = 0) {
        self.major = major
        self.minor = minor
        self.build = build
        self.revision = revision
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.build, lhs.revision) < (rhs.major, rhs.minor, rhs.build, rhs.revision)
    }

    /// `2.5.1`, with the revision only when it isn't 0.
    public var description: String {
        revision == 0 ? "\(major).\(minor).\(build)" : "\(major).\(minor).\(build).\(revision)"
    }

    /// The fixed file version in a DLL's version resource. .NET plugins carry
    /// their assembly version there, which is what other mods depend on.
    ///
    /// Reads the `VS_FIXEDFILEINFO` block by its signature rather than walking
    /// the PE resource tree: a plugin has one version resource, and the
    /// signature followed by its struct version is distinctive enough.
    public static func fileVersion(of url: URL) -> PEVersion? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return fileVersion(in: data)
    }

    static func fileVersion(in data: Data) -> PEVersion? {
        // dwSignature 0xFEEF04BD, then dwStrucVersion 0x00010000, little-endian.
        let signature: [UInt8] = [0xBD, 0x04, 0xEF, 0xFE, 0x00, 0x00, 0x01, 0x00]
        guard let range = data.firstRange(of: Data(signature)) else { return nil }
        let start = range.upperBound
        guard data.count >= start + 8 else { return nil }
        func word(_ offset: Int) -> Int {
            Int(data[start + offset]) | Int(data[start + offset + 1]) << 8
        }
        // dwFileVersionMS holds major.minor, dwFileVersionLS build.revision,
        // each 32-bit value with the high half first.
        return PEVersion(word(2), word(0), word(6), word(4))
    }
}

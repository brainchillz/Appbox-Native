#!/usr/bin/env swift
//
// crop.swift — crop a PNG to a rectangle, for tidying screenshots.
//
//   swift Tools/crop.swift <in.png> <out.png> <x> <y> <width> <height>
//
// Origin is top-left, in pixels.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 7,
      let x = Int(args[3]), let y = Int(args[4]),
      let w = Int(args[5]), let h = Int(args[6])
else {
    FileHandle.standardError.write(
        Data("usage: crop.swift <in.png> <out.png> <x> <y> <w> <h>\n".utf8))
    exit(1)
}

guard let source = NSImage(contentsOfFile: args[1]),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

let rect = CGRect(x: x, y: y, width: w, height: h)
    .intersection(CGRect(x: 0, y: 0, width: cgSource.width, height: cgSource.height))

guard let cropped = cgSource.cropping(to: rect) else {
    FileHandle.standardError.write(Data("crop rectangle is outside the image\n".utf8))
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cropped)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]): \(cropped.width)x\(cropped.height)")

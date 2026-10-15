import AppKit
import ImageIO
import UniformTypeIdentifiers
let folder = CommandLine.arguments[1]
for (name,title,lines,color) in [("stall","iPhone 12 mini — launch trace",["Warm launch: 420 ms", "Cold launch: 2,900 ms", "Main thread blocked on image decode", "Fix: decode off the main thread"],NSColor.systemOrange),("budget","Marketing budget — Q4 review",["Planned spend: $120,000", "Actual spend: $148,000", "Pause the lowest-performing ads", "Priya sends the revised forecast Friday"],NSColor.systemBlue)] {
 let image = NSImage(size: NSSize(width:1200,height:750)); image.lockFocus()
 NSColor.white.setFill();NSRect(x:0,y:0,width:1200,height:750).fill()
 (title as NSString).draw(at:NSPoint(x:70,y:650),withAttributes:[.font:NSFont.boldSystemFont(ofSize:36),.foregroundColor:NSColor.black])
 for (i,line) in lines.enumerated(){(line as NSString).draw(at:NSPoint(x:70,y:550-i*65),withAttributes:[.font:NSFont.systemFont(ofSize:28),.foregroundColor:NSColor.black])}
 color.setFill();for i in 0..<8 { NSRect(x:CGFloat(75+i*130),y:55,width:60,height:CGFloat(i==5 ? 180 : 40+i*8)).fill() }
 image.unlockFocus();let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
 let dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath:folder+"/"+name+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,cg,nil);CGImageDestinationFinalize(dest)
}

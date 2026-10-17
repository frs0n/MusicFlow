import AppKit
import MetalKit
import ImageIO

extension FlowRenderer {
    func artwork(url:URL) throws -> Artwork {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw FlowError("Cannot open image: \(url.lastPathComponent)")}
        // Music caps the longest edge at 300 when pixel count exceeds the device threshold.
        let threshold=device.isLowPower ? 1000 : 100_000
        let scale=image.width*image.height > threshold ? (300/Double(max(image.width,image.height))) : 1
        let w=max(1,Int(Double(image.width)*scale)),h=max(1,Int(Double(image.height)*scale))
        var bytes=[UInt8](repeating:0,count:w*h*4)
        let cs=CGColorSpace(name:CGColorSpace.sRGB)!
        guard let context=CGContext(data:&bytes,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw FlowError("Cannot decode artwork")}
        context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        guard let decoded=context.makeImage() else {throw FlowError("Cannot resize artwork")}
        let tex=try MTKTextureLoader(device:device).newTexture(cgImage:decoded,options:[.SRGB:true,.generateMipmaps:true,.textureStorageMode:MTLStorageMode.private.rawValue,.textureUsage:MTLTextureUsage.shaderRead.rawValue])
        return Artwork(texture:tex,luminosity:musicLuminosityRGBA8(bytes),name:url.deletingPathExtension().lastPathComponent)
    }
    func sampleArtwork(_ seed:Int,highFrequency:Bool=false) -> Artwork {
        let w=300,h=300
        var pixels=[UInt8](repeating:255,count:w*h*4)
        let palettes:[[[Float]]] = [
            [[0.97,0.20,0.12],[0.15,0.02,0.47],[0.98,0.63,0.18],[0.25,0.04,0.13]],
            [[0.03,0.72,0.83],[0.02,0.12,0.42],[0.48,0.78,0.32],[0.04,0.02,0.16]],
            [[0.81,0.32,0.61],[0.29,0.12,0.57],[0.95,0.75,0.52],[0.12,0.17,0.36]]]
        let p=palettes[seed%palettes.count]
        for y in 0..<h {for x in 0..<w {
            let fx=Float(x)/Float(w-1),fy=Float(y)/Float(h-1)
            let wave=(sin(fx*8+cos(fy*5)*2)+1)*0.5
            for c in 0..<3 {
                let top=p[0][c]*(1-fx)+p[1][c]*fx,bottom=p[2][c]*(1-fx)+p[3][c]*fx
                var value=(top*(1-fy)+bottom*fy)*0.7 + p[(x/80+y/70)%4][c]*wave*0.3
                if highFrequency {value=(x/3+y/5)%2==0 ? value : 1-value}
                pixels[(y*w+x)*4+c]=UInt8(max(0,min(255,Int(value*255))))
            }
        }}
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:w,height:h,mipmapped:true)
        desc.usage = .shaderRead;desc.storageMode = .shared
        let t=device.makeTexture(descriptor:desc)!
        pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
        let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!
        blit.generateMipmaps(for:t);blit.endEncoding();command.commit();command.waitUntilCompleted()
        return Artwork(texture:t,luminosity:musicLuminosityRGBA8(pixels),name:["Ember","Tidal","Dusk"][seed%3])
    }
}
// The original alpha-last, premultiplied, 32-bit RGB branch at 0x100e06fc4.
func musicLuminosityRGBA8(_ pixels:[UInt8])->Float {
    var sum:Float=0,count:Float=0
    for i in stride(from:0,to:pixels.count,by:4) {
        let alpha=Int(pixels[i+3]);if alpha==0 {continue}
        let r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2])
        if r+g+b>0 {
            let rounded=((r*4915+g*9667+b*1802+8192)>>6)&65535
            sum += Float(rounded/alpha)
        }
        count+=1
    }
    return count*255 < 1 ? sum : sum/(count*255)
}

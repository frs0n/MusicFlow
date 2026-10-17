import Foundation
import MetalKit
import ImageIO
import UniformTypeIdentifiers

struct PixelDifference:Codable {
    let mean:Double,max:Int,percentExact:Double,percentWithin1:Double
}
func difference(_ a:[UInt8],_ b:[UInt8],format:MTLPixelFormat)->PixelDifference {
    var sum:Double=0,maxD=0,exact=0,within=0,count=0
    for i in stride(from:0,to:a.count,by:4) {
        if format == .bgr10a2Unorm {
            let x=UInt32(a[i])|UInt32(a[i+1])<<8|UInt32(a[i+2])<<16|UInt32(a[i+3])<<24
            let y=UInt32(b[i])|UInt32(b[i+1])<<8|UInt32(b[i+2])<<16|UInt32(b[i+3])<<24
            for s in [0,10,20] {let d=abs(Int((x>>s)&1023)-Int((y>>s)&1023));sum+=Double(d);maxD=max(maxD,d);exact += d==0 ? 1:0;within += d<=1 ? 1:0;count+=1}
        } else {
            for c in 0..<3{let d=abs(Int(a[i+c])-Int(b[i+c]));sum+=Double(d);maxD=max(maxD,d);exact += d==0 ? 1:0;within += d<=1 ? 1:0;count+=1}
        }
    }
    return PixelDifference(mean:sum/Double(count),max:maxD,percentExact:Double(exact)*100/Double(count),percentWithin1:Double(within)*100/Double(count))
}
func runValidation(output:URL) throws {
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let r=try FlowRenderer(loadOriginal:true)
    let baseSource=r.sampleArtwork(0,highFrequency:true),dest=r.sampleArtwork(1,highFrequency:true)
    var rows:[[String:Any]]=[]
    let times:[Float]=[0,0.37,1.75,6.2,45.25]
    for (width,height) in [(960,640),(511,769),(320,320)] {
    for fallback in [false,true] {
        r.fallbackBlur=fallback
        for mesh in 0..<5 {
            for (k,time) in times.enumerated() {
                var source=baseSource
                source.usesReplacementColors=k==4
                var p=FlowParameters();p.time=time;p.meshIndex=mesh;p.dark=k%2==0;p.transitionMix=k==0 || k==4 ? 0:0.43
                let dst=p.transitionMix>0 && k != 2 ? dest:nil
                r.originalStages=[]
                let ours=try r.render(p,source:source,destination:dst,width:width,height:height)
                let oursFinal=r.readBytes(ours.output),oursRotation=r.readBytes(ours.rotation),oursBlur=r.readBytes(ours.blurred)
                if width==960 && !fallback && mesh==0 && k==3 {try r.savePNG(ours.output,to:output.appendingPathComponent("reconstructed.png"))}
                r.originalStages=["rotation","pinch","blur"]
                let native=try r.render(p,source:source,destination:dst,width:width,height:height)
                let f=difference(oursFinal,r.readBytes(native.output),format:r.format)
                let rot=difference(oursRotation,r.readBytes(native.rotation),format:r.format)
                let blur=difference(oursBlur,r.readBytes(native.blurred),format:r.format)
                let encoder=JSONEncoder()
                func json(_ x:PixelDifference)->Any {try! JSONSerialization.jsonObject(with:encoder.encode(x))}
                rows.append(["placeholder":source.usesReplacementColors,"width":width,"height":height,"mesh":mesh,"time":time,"dark":p.dark,"mix":p.transitionMix,"blur":fallback ? "separable":"MPS","rotation":json(rot),"blurred":json(blur),"final":json(f)])
                print("mesh=\(mesh) t=\(time) \(fallback ? "separable":"MPS") mean=\(f.mean) max=\(f.max) within1=\(f.percentWithin1)% rotation=\(rot.mean)")
                if width==960 && !fallback && mesh==0 && k==3 {try r.savePNG(native.output,to:output.appendingPathComponent("original-shaders.png"))}
            }
        }
    }
    }
    let report:[String:Any]=["device":r.device.name,"pixelFormat":r.format.rawValue,"channelScale":r.format == .bgr10a2Unorm ? 1023:255,"inputTexture":"mipmapped rgba8Unorm_srgb, 300 x 300", "scope":"Identical reconstructed CPU pipeline and mesh input; original metallib shader functions versus rewritten Metal. Does not establish full Apple Music runtime CPU equivalence.","cases":rows]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("comparison.json"))
    let relevantStages=["rotation","blurred","final"]
    let allExact=rows.allSatisfy { row in relevantStages.allSatisfy { ((row[$0] as? [String:Any])?["max"] as? Int) == 0 } }
    if !allExact { throw FlowError("Pixel differences found; inspect comparison.json") }
    let worst = rows.compactMap { ($0["final"] as? [String:Any])?["max"] as? Int }.max() ?? 0
    print("Validated \(rows.count) cases; worst final channel error = \(worst)")
    r.originalStages=[]
    var p=FlowParameters();p.time=6.2;p.meshIndex=0
    r.fallbackBlur=false
    let a=r.sampleArtwork(0)
    let frame=try r.render(p,source:a,width:960,height:640)
    try r.savePNG(frame.output,to:output.appendingPathComponent("preview.png"))
    let loaded=try r.artwork(url:output.appendingPathComponent("preview.png"))
    guard loaded.texture.width==300,loaded.texture.height==200,loaded.texture.mipmapLevelCount>1 else {throw FlowError("Artwork preprocessing mismatch")}
    _ = try r.render(p,source:loaded,width:320,height:320)
    print("PNG artwork loaded, resized to 300x200, mipmaps and GPU render verified")
    let gifURL=output.appendingPathComponent("animation.gif")
    if let gif=CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,40,nil) {
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<40 {
            p.time=Float(i)/10
            let t=try r.render(p,source:a,width:480,height:320)
            let image=try r.cgImage(t.output)
            CGImageDestinationAddImage(gif,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else {throw FlowError("Cannot export animation")}
    }

}

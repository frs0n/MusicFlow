import AppKit
import MetalKit
import MetalPerformanceShaders

final class FlowRenderer {
    let device:MTLDevice
    let queue:MTLCommandQueue
    let reconstructed:MTLLibrary
    let original:MTLLibrary?
    let format:MTLPixelFormat
    let meshes:[SubdividedMesh]
    let quad:MTLBuffer, quadIndices:MTLBuffer
    var meshBuffers:[(MTLBuffer,MTLBuffer,Int)]=[]
    private var pipelines:[String:MTLRenderPipelineState]=[:]
    private var targets:FrameTextures?
    private var intermediate:MTLTexture?
    private var blur:MPSImageGaussianBlur?
    private var blurSigma:Float = -1
    var originalStages:Set<String>=[]
    var fallbackBlur=false

    init(device:MTLDevice?=MTLCreateSystemDefaultDevice(), loadOriginal:Bool=false, format:MTLPixelFormat?=nil) throws {
        guard let d=device, let q=d.makeCommandQueue() else {throw FlowError("Metal device unavailable")}
        self.device=d;queue=q
        self.format=format ?? (d.supportsFamily(.apple2) ? .bgr10a2Unorm : .bgra8Unorm)
        let options=MTLCompileOptions();options.fastMathEnabled=true
        reconstructed=try d.makeLibrary(source:String(contentsOf:resourceURL("Flow.metal")),options:options)
        original=loadOriginal ? try d.makeLibrary(URL:URL(fileURLWithPath:"/System/Applications/Music.app/Contents/Resources/default.metallib")) : nil
        meshes=try JSONDecoder().decode([SubdividedMesh].self,from:Data(contentsOf:resourceURL("SubdividedMeshes.json")))
        let quadData=try Data(contentsOf:resourceURL("QuadVertices.bin"))
        quad=quadData.withUnsafeBytes{d.makeBuffer(bytes:$0.baseAddress!,length:quadData.count,options:.storageModeShared)!}
        let qi:[UInt16]=[0,1,2,2,3,0]
        quadIndices=d.makeBuffer(bytes:qi,length:qi.count*2,options:.storageModeShared)!
        for mesh in meshes {
            var vertices:[Float]=[]
            for (from,to) in zip(mesh.initial.vertices,mesh.morphed.vertices) {
                vertices += [Float(from[0]),Float(from[1]),0,1,
                             Float(from[2]),Float(from[3]),Float(from[4]),1,
                             Float(to[2]),Float(to[3]),Float(to[4]),1,
                             Float(from[0]),Float(from[1])]
            }
            var indices:[UInt16]=[]
            for face in mesh.initial.faces {indices += [face[0],face[2],face[3],face[0],face[1],face[2]].map{UInt16($0)}}
            meshBuffers.append((d.makeBuffer(bytes:vertices,length:vertices.count*4,options:.storageModeShared)!,d.makeBuffer(bytes:indices,length:indices.count*2,options:.storageModeShared)!,indices.count))
        }
    }
    func function(_ name:String)->MTLFunction? {
        let originalStage = name.hasPrefix("rotation") ? "rotation" : name.hasPrefix("pinch") ? "pinch" : "blur"
        return (originalStages.contains(originalStage) ? original : reconstructed)?.makeFunction(name:name)
    }
    func pipeline(vertex:String,fragment:String,display:Bool=false,outputFormat:MTLPixelFormat?=nil) throws -> MTLRenderPipelineState {
        let key="\(vertex)/\(fragment)/\(display)/\(originalStages.sorted())/\(outputFormat?.rawValue ?? 0)"
        if let p=pipelines[key]{return p}
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=display ? reconstructed.makeFunction(name:vertex) : function(vertex)
        descriptor.fragmentFunction=display ? reconstructed.makeFunction(name:fragment) : function(fragment)
        descriptor.colorAttachments[0].pixelFormat=outputFormat ?? (display ? .bgra8Unorm : format)
        descriptor.colorAttachments[0].isBlendingEnabled=false
        if !display {
            let vd=MTLVertexDescriptor()
            if vertex=="pinch_vertex" {
                for (i,offset) in [0,16,32,48].enumerated(){vd.attributes[i].format=i==3 ? .float2 : .float4;vd.attributes[i].offset=offset;vd.attributes[i].bufferIndex=0}
                vd.layouts[0].stride=56
            } else {
                vd.attributes[0].format = .float4;vd.attributes[0].offset=0;vd.attributes[0].bufferIndex=0
                vd.attributes[1].format = .float2;vd.attributes[1].offset=16;vd.attributes[1].bufferIndex=0
                vd.layouts[0].stride=24
            }
            descriptor.vertexDescriptor=vd
        }
        let result=try device.makeRenderPipelineState(descriptor:descriptor)
        pipelines[key]=result;return result
    }
    func texture(width:Int,height:Int,format:MTLPixelFormat?=nil)->MTLTexture {
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format ?? self.format,width:max(1,width),height:max(1,height),mipmapped:false)
        desc.usage=[.shaderRead,.shaderWrite,.renderTarget];desc.storageMode = .private
        return device.makeTexture(descriptor:desc)!
    }
    private func ensureTargets(width:Int,height:Int)->FrameTextures {
        let w=max(1,min(16384,width)),h=max(1,min(16384,height))
        if let t=targets,t.output.width==w,t.output.height==h{return t}
        let t=FrameTextures(rotation:texture(width:w,height:h),blurred:texture(width:w,height:h),output:texture(width:w,height:h))
        intermediate=texture(width:w,height:h);targets=t;return t
    }
    func encoder(_ command:MTLCommandBuffer,to:MTLTexture,label:String)->MTLRenderCommandEncoder {
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=to
        pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
        let e=command.makeRenderCommandEncoder(descriptor:pass)!;e.label=label;return e
    }
    func bind(_ values:[Float],to e:MTLRenderCommandEncoder,vertex:Bool=true,index:Int=1) {
        values.withUnsafeBytes { bytes in
            if vertex {e.setVertexBytes(bytes.baseAddress!,length:bytes.count,index:index)}
            e.setFragmentBytes(bytes.baseAddress!,length:bytes.count,index:index)
        }
    }
    // Color replacements are used for artwork unavailable states, not synthesized from artwork.
    func replacementColors(dark:Bool,enabled:Bool)->[Float] {
        var c:[Float]=dark ? [0.306,0,0,0,0.173,0,0,0,0.11,0,0,0] : [1,0,0,0,0.922,0,0,0,0.8,0,0,0]
        c += [enabled ? 1:0,0,0,0];return c
    }
    func encodeFrame(_ p:FlowParameters,source:Artwork,destination:Artwork?=nil,width:Int,height:Int,command:MTLCommandBuffer) throws -> FrameTextures {
        let t=ensureTargets(width:width,height:height)
        let rotation=encoder(command,to:t.rotation,label:"Artwork: three rotating instances")
        rotation.setRenderPipelineState(try pipeline(vertex:"rotation_vertex",fragment:destination==nil ? "rotation_fragmentNoDestinationTexture" : "rotation_fragment"))
        rotation.setVertexBuffer(quad,offset:0,index:0)
        bind(uniforms(p,stage:0,luminosity:source.luminosity),to:rotation)
        bind(replacementColors(dark:p.dark,enabled:source.usesReplacementColors),to:rotation,vertex:false,index:2)
        bind(replacementColors(dark:p.dark,enabled:destination?.usesReplacementColors ?? true),to:rotation,vertex:false,index:3)
        rotation.setFragmentTexture(source.texture,index:0)
        if let dst=destination {rotation.setFragmentTexture(dst.texture,index:1)}
        rotation.drawIndexedPrimitives(type:.triangle,indexCount:6,indexType:.uint16,indexBuffer:quadIndices,indexBufferOffset:0,instanceCount:3)
        rotation.endEncoding()
        let sigma=p.blurOverride.map{Float(ceil($0/3.034853935241699))} ?? Float(floor(hypot(Double(t.output.width),Double(t.output.height))*0.04539470697716646))
        if !fallbackBlur {
            if sigma != blurSigma {
                let b=MPSImageGaussianBlur(device:device,sigma:max(0.01,sigma));b.options=MPSKernelOptions(rawValue:6);b.edgeMode = .zero
                blur=b;blurSigma=sigma
            }
            blur!.encode(commandBuffer:command,sourceTexture:t.rotation,destinationTexture:t.blurred)
        } else {
            let weights=gaussianWeights(sigma:min(80,max(1,Int(sigma))))
            for (shader,input,output) in [("gaussianHorizontalBlur",t.rotation,intermediate!),("gaussianVerticalBlur",intermediate!,t.blurred)] {
                let e=encoder(command,to:output,label:shader)
                e.setRenderPipelineState(try pipeline(vertex:"blur_vertex",fragment:shader))
                e.setVertexBuffer(quad,offset:0,index:0);e.setFragmentTexture(input,index:0)
                bind(weights,to:e,vertex:false,index:1)
                e.drawIndexedPrimitives(type:.triangle,indexCount:6,indexType:.uint16,indexBuffer:quadIndices,indexBufferOffset:0);e.endEncoding()
            }
        }
        let pinch=encoder(command,to:t.output,label:"Artwork: morph mesh and scrim")
        pinch.setRenderPipelineState(try pipeline(vertex:"pinch_vertex",fragment:"pinch_fragment"))
        let mesh=meshBuffers[max(0,min(4,p.meshIndex))]
        pinch.setVertexBuffer(mesh.0,offset:0,index:0)
        bind(uniforms(p,stage:1,luminosity:source.luminosity),to:pinch)
        pinch.setFragmentTexture(t.blurred,index:0)
        pinch.drawIndexedPrimitives(type:.triangle,indexCount:mesh.2,indexType:.uint16,indexBuffer:mesh.1,indexBufferOffset:0)
        pinch.endEncoding()
        return t
    }
    func render(_ p:FlowParameters,source:Artwork,destination:Artwork?=nil,width:Int,height:Int) throws -> FrameTextures {
        let command=queue.makeCommandBuffer()!
        let result=try encodeFrame(p,source:source,destination:destination,width:width,height:height,command:command)
        command.commit();command.waitUntilCompleted()
        if let error=command.error{throw error};return result
    }
    func present(_ texture:MTLTexture,command:MTLCommandBuffer,pass:MTLRenderPassDescriptor) throws {
        let e=command.makeRenderCommandEncoder(descriptor:pass)!
        e.setRenderPipelineState(try pipeline(vertex:"display_vertex",fragment:"display_fragment",display:true,outputFormat:pass.colorAttachments[0].texture?.pixelFormat))
        e.setFragmentTexture(texture,index:0);e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
    }
    func readBytes(_ t:MTLTexture)->[UInt8] {
        let row=((t.width*4+255)/256)*256
        let b=device.makeBuffer(length:row*t.height,options:.storageModeShared)!
        let cmd=queue.makeCommandBuffer()!,blit=cmd.makeBlitCommandEncoder()!
        blit.copy(from:t,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:t.width,height:t.height,depth:1),to:b,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:row*t.height)
        blit.endEncoding();cmd.commit();cmd.waitUntilCompleted()
        var bytes=[UInt8](repeating:0,count:t.width*t.height*4)
        for y in 0..<t.height {bytes.withUnsafeMutableBytes{$0.baseAddress!.advanced(by:y*t.width*4).copyMemory(from:b.contents().advanced(by:y*row),byteCount:t.width*4)}}
        return bytes
    }
    func cgImage(_ texture:MTLTexture) throws -> CGImage {
        let target=self.texture(width:texture.width,height:texture.height,format:.bgra8Unorm)
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
        let c=queue.makeCommandBuffer()!;try present(texture,command:c,pass:pass);c.commit();c.waitUntilCompleted()
        let raw=readBytes(target)
        let provider=CGDataProvider(data:Data(raw) as CFData)!
        let image=CGImage(width:target.width,height:target.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:target.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        return image
    }
    func savePNG(_ texture:MTLTexture,to url:URL) throws {
        let rep=NSBitmapImageRep(cgImage:try cgImage(texture))
        try rep.representation(using:.png,properties:[:])!.write(to:url)
    }
}
func gaussianWeights(sigma:Int)->[Float] {
    let n=Int(ceil(Double(sigma)*3.0348542587702925))|1,mid=n/2
    var w=[Float](repeating:0,count:max(125,n));var sum=0.0
    for i in 0...mid {
        let value=exp(-Double(i*i)/(2*Double(sigma*sigma)))/sqrt(Double(sigma)*2*Double.pi)
        w[mid-i]=Float(value);w[mid+i]=Float(value);sum+=value
    }
    let inverse=Float(1/(sum*2-Double(w[mid])))
    for i in 0..<n {w[i] *= inverse}
    return w
}

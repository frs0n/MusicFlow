import AppKit
import MetalKit
import simd

struct FlowError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ s:String){message=s} }
struct SubdividedMesh: Decodable {
    struct Shape: Decodable { let vertices:[[Double]]; let faces:[[Int]] }
    let index:Int; let initial:Shape; let morphed:Shape
}
struct FlowParameters {
    var time:Float=0, animationInterval:Float=0.5, transitionMix:Float=0
    var dark=true, reduceMotion=false, meshIndex=0
    var whiteScrimAlpha:Float=0.25, blackScrimAlpha:Float=0.25
    var blurOverride:Float?=nil
}
struct Artwork {
    let texture:MTLTexture
    let luminosity:Float
    let name:String
    var usesReplacementColors=false
}
struct FrameTextures {
    let rotation:MTLTexture
    let blurred:MTLTexture
    let output:MTLTexture
}
func resourceURL(_ name:String)->URL { Bundle.module.resourceURL!.appendingPathComponent("Resources").appendingPathComponent(name) }
func setMatrix(_ m:simd_float4x4, in values:inout [Float], at offset:Int) {
    for c in 0..<4 {for r in 0..<4 { values[offset+c*4+r]=m[c][r] }}
}
func uniforms(_ p:FlowParameters, stage:Int, luminosity:Float)->[Float] {
    var u=[Float](repeating:0,count:92)
    setMatrix(matrix_identity_float4x4,in:&u,at:0)
    let interval=p.reduceMotion ? 5 : min(10,max(0.1,p.animationInterval))
    u[16]=p.time;u[17]=p.transitionMix;u[18]=interval*3.5
    u[19]=stage==0 ? 1.3 : 2
    u[20]=p.whiteScrimAlpha;u[21]=p.blackScrimAlpha
    u[22]=p.dark ? 0.2 : 0;u[23]=p.dark ? 0 : (luminosity<0.3 ? 0.38 : 0.08)
    u[24]=0.07;u[25]=0.97
    var m1=matrix_identity_float4x4,m2=m1
    m1.columns.3=SIMD4(-0.5,0.7,0,1);m2.columns.3=SIMD4(-0.95,-0.7,0,1)
    for (i,m) in [matrix_identity_float4x4,m1,m2].enumerated(){
        setMatrix(m,in:&u,at:32+i*20);u[48+i*20]=interval*[120,90,70][i]
    }
    return u
}

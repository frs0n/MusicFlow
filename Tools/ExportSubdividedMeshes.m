#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <stdio.h>
extern NSString * const kCADepthNormalizationNone;
typedef struct { CGPoint from; struct { double x,y,z; } to; } MeshVertex;
typedef struct { uint32_t indices[4]; float weights[4]; } MeshFace;
@interface NSObject (MeshRead)
+ (id)meshTransformWithVertexCount:(NSUInteger)n vertices:(const MeshVertex*)v faceCount:(NSUInteger)m faces:(const MeshFace*)f depthNormalization:(NSString*)normalization;
- (id)subdividedMesh:(NSUInteger)levels;
- (NSUInteger)vertexCount;
- (NSUInteger)faceCount;
- (MeshVertex)vertexAtIndex:(NSUInteger)index;
- (MeshFace)faceAtIndex:(NSUInteger)index;
@end
int main(int argc,const char**argv){ @autoreleasepool {
 if(argc!=3) return 2;
 NSArray *templates=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
 Class cls=NSClassFromString(@"CAMeshTransform"); if(!cls){fprintf(stderr,"CAMeshTransform unavailable\n");return 3;}
 NSMutableArray *out=[NSMutableArray array];
 for(NSDictionary *item in templates){
  NSMutableArray *pair=[NSMutableArray array];
  for(NSString *key in @[@"initial",@"morphed"]){
   MeshVertex vertices[36]={0};MeshFace faces[25]={0};NSArray *p=item[key];
   for(int y=0;y<6;y++)for(int x=0;x<6;x++){int i=y*6+x;vertices[i]=(MeshVertex){{x/5.0,y/5.0},{[p[i][0] doubleValue]*2-1,[p[i][1] doubleValue]*2-1,0.5}};}
   for(int y=0;y<5;y++)for(int x=0;x<5;x++){int i=y*5+x,n=y*6+x;faces[i]=(MeshFace){{n,n+1,n+7,n+6},{0,0,0,0}};}
   id mesh=[[cls meshTransformWithVertexCount:36 vertices:vertices faceCount:25 faces:faces depthNormalization:kCADepthNormalizationNone] subdividedMesh:3];
   if(!mesh){fprintf(stderr,"subdivision failed\n");return 4;}
   NSMutableArray *vv=[NSMutableArray array],*ff=[NSMutableArray array];
   for(NSUInteger i=0;i<[mesh vertexCount];i++){MeshVertex v=[mesh vertexAtIndex:i];[vv addObject:@[@(v.from.x),@(v.from.y),@(v.to.x),@(v.to.y),@(v.to.z)]];}
   for(NSUInteger i=0;i<[mesh faceCount];i++){MeshFace f=[mesh faceAtIndex:i];[ff addObject:@[@(f.indices[0]),@(f.indices[1]),@(f.indices[2]),@(f.indices[3])]];}
   [pair addObject:@{@"vertices":vv,@"faces":ff}];
  }
  [out addObject:@{@"index":item[@"index"],@"initial":pair[0],@"morphed":pair[1]}];
 }
 NSData *json=[NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
 if(![json writeToFile:@(argv[2]) atomically:YES])return 5;
 fprintf(stderr,"exported %lu templates\n",(unsigned long)out.count);
 }return 0;}

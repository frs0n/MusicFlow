import AppKit
import MetalKit
import UniformTypeIdentifiers

final class FlowView:MTKView,MTKViewDelegate {
    let renderer:FlowRenderer
    var parameters=FlowParameters()
    var artwork:Artwork
    var nextArtwork:Artwork?
    var pendingArtwork:Artwork?
    var onError:((String)->Void)?
    var animationPaused=false
    private var frames=0
    init(configure:Bool=true) throws {
        renderer=try FlowRenderer()
        artwork=renderer.sampleArtwork(0)
        super.init(frame:.zero,device:renderer.device)
        colorPixelFormat = renderer.format;framebufferOnly=false
        preferredFramesPerSecond=60;enableSetNeedsDisplay=false;isPaused=false
        delegate=self
        NotificationCenter.default.addObserver(self,selector:#selector(motionChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
        motionChanged()
    }
    required init(coder:NSCoder){fatalError()}
    @objc func motionChanged(){parameters.reduceMotion=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    func changeArtwork(_ a:Artwork) {
        if nextArtwork != nil {pendingArtwork=a;return}
        nextArtwork=a;parameters.transitionMix=1
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    func draw(in view:MTKView) {
        guard let drawable=currentDrawable,let pass=currentRenderPassDescriptor else{return}
        if !animationPaused {
            parameters.time += 1/Float(preferredFramesPerSecond)
            if nextArtwork != nil {
                parameters.transitionMix=max(0,parameters.transitionMix-1/Float(preferredFramesPerSecond)/0.5)
                if parameters.transitionMix==0 {
                    artwork=nextArtwork!;nextArtwork=nil
                    if let pending=pendingArtwork {pendingArtwork=nil;changeArtwork(pending)}
                }
            }
        }
        do {
            let command=renderer.queue.makeCommandBuffer()!
            // The ordered Metal queue serializes writes to the reused targets.
            let texture=try renderer.encodeFrame(parameters,source:artwork,destination:nextArtwork,width:Int(drawableSize.width),height:Int(drawableSize.height),command:command).output
            try renderer.present(texture,command:command,pass:pass)
            command.present(drawable);command.commit()
            frames+=1
        } catch {isPaused=true;onError?(error.localizedDescription)}
    }
}
final class AppDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!,flow:FlowView!
    var sample=0
    func applicationDidFinishLaunching(_ notification:Notification) {
        do {flow=try FlowView()} catch {NSAlert(error:error).runModal();NSApp.terminate(nil);return}
        let menu=NSMenu();let appItem=NSMenuItem();menu.addItem(appItem)
        let appMenu=NSMenu();appItem.submenu=appMenu
        appMenu.addItem(withTitle:"Quit MusicFlow",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="MusicFlow · Metal";window.minSize=NSSize(width:960,height:360)
        let root=NSView();window.contentView=root
        let bar=NSStackView();bar.orientation = .horizontal;bar.spacing=12;bar.edgeInsets=NSEdgeInsets(top:10,left:16,bottom:10,right:16)
        let open=NSButton(title:"Open Artwork…",target:self,action:#selector(openArtwork));bar.addArrangedSubview(open)
        bar.addArrangedSubview(NSButton(title:"Next Sample",target:self,action:#selector(nextSample)))
        bar.addArrangedSubview(NSButton(title:"Pause / Resume",target:self,action:#selector(togglePause)))
        let dark=NSButton(checkboxWithTitle:"Dark",target:self,action:#selector(toggleDark(_:)));dark.state = .on;bar.addArrangedSubview(dark)
        let mesh=NSPopUpButton();mesh.addItems(withTitles:(0..<5).map{"Mesh \($0+1)"});mesh.target=self;mesh.action=#selector(changeMesh(_:));bar.addArrangedSubview(mesh)
        let label=NSTextField(labelWithString:"Time Scale");bar.addArrangedSubview(label)
        let speed=NSSlider(value:0.5,minValue:0.1,maxValue:3,target:self,action:#selector(speedChanged(_:)));speed.widthAnchor.constraint(equalToConstant:110).isActive=true;bar.addArrangedSubview(speed)
        bar.addArrangedSubview(NSButton(title:"Save Frame",target:self,action:#selector(saveFrame)))
        for v in [flow!,bar] {v.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(v)}
        NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo:root.topAnchor),bar.leadingAnchor.constraint(equalTo:root.leadingAnchor),bar.trailingAnchor.constraint(lessThanOrEqualTo:root.trailingAnchor),flow.topAnchor.constraint(equalTo:bar.bottomAnchor),flow.leadingAnchor.constraint(equalTo:root.leadingAnchor),flow.trailingAnchor.constraint(equalTo:root.trailingAnchor),flow.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        flow.onError={message in NSAlert(error:FlowError(message)).runModal()}
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        if let i=CommandLine.arguments.firstIndex(of:"--image"),i+1<CommandLine.arguments.count {
            do{flow.artwork=try flow.renderer.artwork(url:URL(fileURLWithPath:CommandLine.arguments[i+1]))}catch{NSAlert(error:error).runModal()}
        }
    }
    @objc func openArtwork(){let p=NSOpenPanel();p.allowedContentTypes=[.image];p.beginSheetModal(for:window){[weak self] response in guard response == .OK,let self,let url=p.url else{return};do{self.flow.changeArtwork(try self.flow.renderer.artwork(url:url))}catch{NSAlert(error:error).beginSheetModal(for:self.window)}}}
    @objc func nextSample(){sample=(sample+1)%3;flow.changeArtwork(flow.renderer.sampleArtwork(sample))}
    @objc func togglePause(){flow.animationPaused.toggle()}
    @objc func toggleDark(_ b:NSButton){flow.parameters.dark=b.state == .on}
    @objc func changeMesh(_ p:NSPopUpButton){flow.parameters.meshIndex=p.indexOfSelectedItem}
    @objc func speedChanged(_ s:NSSlider){flow.parameters.animationInterval=Float(s.doubleValue)}
    @objc func saveFrame(){let p=NSSavePanel();p.allowedContentTypes=[.png];p.nameFieldStringValue="MusicFlow.png";p.beginSheetModal(for:window){[weak self] response in guard response == .OK,let self,let url=p.url else{return};do{let t=try self.flow.renderer.render(self.flow.parameters,source:self.flow.artwork,destination:self.flow.nextArtwork,width:Int(self.flow.drawableSize.width),height:Int(self.flow.drawableSize.height));try self.flow.renderer.savePNG(t.output,to:url)}catch{NSAlert(error:error).beginSheetModal(for:self.window)}}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}

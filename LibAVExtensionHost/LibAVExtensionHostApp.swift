//
//  LibAVExtensionHostApp.swift
//  LibAVExtensionHost
//
//  Created by Anton Marini on 7/25/24.
//

import SwiftUI
import MediaToolbox
import VideoToolbox
import AVFoundation

@main
struct LibAVExtensionHostApp: App
{
    let asset: AVAsset
    init()
    {
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()

        // Has GOP
        let url = URL(filePath:"/Users/vade/test.mkv")
        
        // All Key Frames
//        let url = URL(filePath:"/Users/vade/output.mkv")
                
        self.asset = AVURLAsset(url: url,  options: [AVURLAssetPreferPreciseDurationAndTimingKey : true])
        
        print(self.asset.duration)
    }
    
    var body: some Scene
    {
        WindowGroup
        {
            ContentView(asset: self.asset)
        }
    }
}

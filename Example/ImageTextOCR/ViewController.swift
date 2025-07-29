//
//  ViewController.swift
//  ImageTextOCR
//
//  Created by dopemax on 07/18/2025.
//  Copyright (c) 2025 dopemax. All rights reserved.
//

import UIKit
import ImageTextOCR

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        ImageTextService.shared.start()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

}


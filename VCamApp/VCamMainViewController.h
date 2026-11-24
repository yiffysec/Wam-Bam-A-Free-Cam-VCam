#pragma once
#import <UIKit/UIKit.h>

/// The companion app's root control surface.
///
/// This view controller is the authoritative UI for the whole tweak. The
/// SpringBoard HUD is a shortcut layered on top of it; if the HUD is missing
/// or unresponsive every capability remains reachable here, and a banner plus
/// a manual override toggle explain the situation.
@interface VCamMainViewController : UITableViewController
@end

#pragma once
#import <UIKit/UIKit.h>

/// Shows what the camera daemon is actually doing: which hooks installed, how
/// many frames it has seen versus replaced, which delivery tier is active, and
/// the last error it published.
///
/// This screen is the difference between "it doesn't work" and "tier 0
/// installed 4 of 6 hooks and has replaced 0 of 1,847 frames". It refreshes
/// while visible and stops when it is not.
@interface VCamDiagnosticsViewController : UITableViewController
@end

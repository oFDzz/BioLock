#import <Preferences/PSViewController.h>
#import <LocalAuthentication/LocalAuthentication.h>

@interface BLRootListController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@end

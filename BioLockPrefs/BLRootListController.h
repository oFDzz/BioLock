#import <Preferences/PSViewController.h>

@interface BLRootListController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@end

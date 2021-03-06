//
//  SyndicationAppDelegate.m
//  Syndication
//
//  Created by Calvin Lough on 12/30/10.
//  Copyright 2010 Calvin Lough. All rights reserved.
//

#import "CLActivityView.h"
#import "CLClassicView.h"
#import "CLConstants.h"
#import "CLDatabaseHelper.h"
#import "CLDatabaseUpdateOperation.h"
#import "CLDeleteHiddenOperation.h"
#import "CLErrorHelper.h"
#import "CLFeedParserOperation.h"
#import "CLFeedRequest.h"
#import "CLFeedSheetController.h"
#import "CLHTMLFilter.h"
#import "CLIconRefreshOperation.h"
#import "CLKeychainHelper.h"
#import "CLLaunchServicesHelper.h"
#import "CLPost.h"
#import "CLPreferencesWindow.h"
#import "CLRequest.h"
#import "CLSourceListFeed.h"
#import "CLSourceListFolder.h"
#import "CLTabView.h"
#import "CLTabViewItem.h"
#import "CLTimelineView.h"
#import "CLTimelineViewItem.h"
#import "CLTimelineViewItemView.h"
#import "CLTimer.h"
#import "CLXMLNode.h"
#import "CLXMLParser.h"
#import "CLWebTab.h"
#import "CLWebView.h"
#import "CLWindowController.h"
#import "SyndicationAppDelegate.h"
#import "FMDatabase.h"
#import "FMResultSet.h"
#import "GTMNSString+HTML.h"
#import "JSONKit.h"
#import "NSFileManager+CLAdditions.h"
#import "NSImage+CLAdditions.h"
#import "NSScrollView+CLAdditions.h"
#import "NSString+CLAdditions.h"

#define ICON_REFRESH_INTERVAL TIME_INTERVAL_MONTH
#define PREFERENCES_TOOLBAR_GENERAL_ITEM @"ToolbarItemGeneral"
#define PREFERENCES_TOOLBAR_FONTS_ITEM @"ToolbarItemFonts"
#define PREFERENCES_TOOLBAR_GENERAL_HEIGHT 216 // note: the height of the window in the nib file has to be the same as this
#define PREFERENCES_TOOLBAR_FONTS_HEIGHT 100
#define PREFERENCES_CHECK_FOR_NEW_ARTICLES_KEY @"checkForNewArticles"
#define PREFERENCES_REMOVE_ARTICLES_KEY @"removeArticles"
#define PREFERENCES_MARK_ARTICLES_AS_READ_KEY @"markArticlesAsRead"
#define PREFERENCES_DISPLAY_UNREAD_COUNT_IN_DOCK_KEY @"displayUnreadCountInDock"
#define UNREAD_COUNT_QUERY @"UPDATE feed SET UnreadCount = (SELECT COUNT(Id) FROM post WHERE FeedId=? AND IsRead=0 AND IsHidden=0) WHERE Id=?"
#define MAX_CONCURRENT_REQUESTS 2

@implementation SyndicationAppDelegate

static NSMutableDictionary *timelineUnreadItemsDict;
static NSArray *preferencesToolbarItems;

@synthesize subscriptionList;
@synthesize feedLookupDict;
@synthesize operationQueue;
@synthesize feedSyncTimer;
@synthesize feedsToSync;
@synthesize feedRequests;
@synthesize numberOfActiveParseOps;
@synthesize requestQueue;
@synthesize requestInProgress;
@synthesize activeRequestType;
@synthesize iconRefreshTimers;
@synthesize activityViewFeeds;
@synthesize windowControllers;
@synthesize subscriptionsMenu;
@synthesize totalUnread;
@synthesize preferencesWindow;
@synthesize preferencesToolbar;
@synthesize preferencesTabView;
@synthesize preferencesFeedReaderPopUp;
@synthesize preferencesContentHeight;
@synthesize preferenceCheckForNewArticles;
@synthesize preferenceRemoveArticles;
@synthesize preferenceMarkArticlesAsRead;
@synthesize preferenceDisplayUnreadCountInDock;
@synthesize preferencesHeadlineTextField;
@synthesize preferenceHeadlineFontName;
@synthesize preferenceHeadlineFontSize;
@synthesize preferencesBodyTextField;
@synthesize preferenceBodyFontName;
@synthesize preferenceBodyFontSize;
@synthesize isFirstWindow;
@synthesize opmlLoadingWindow;
@synthesize opmlLoadingProgressIndicator;
@synthesize inLiveResize;
@synthesize windowForUpdate;
@synthesize hasFinishedLaunching;
@synthesize feedEventString;

+ (void)initialize {
	timelineUnreadItemsDict = [[NSMutableDictionary alloc] init];
	preferencesToolbarItems = [[NSArray arrayWithObjects:PREFERENCES_TOOLBAR_GENERAL_ITEM, PREFERENCES_TOOLBAR_FONTS_ITEM, nil] retain];
}

+ (BOOL)isSourceListItem:(CLSourceListItem *)item descendentOf:(CLSourceListItem *)parent {
	while (item != nil) {
		if (item == parent) {
			return YES;
		}
		
		if ([item isKindOfClass:[CLSourceListFeed class]]) {
			item = [(CLSourceListFeed *)item enclosingFolderReference];
		} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
			item = [(CLSourceListFolder *)item parentFolderReference];
		} else {
			item = nil; // this prevents an infinite loop if we get something other that the two types that we can handle
		}
	}

	return NO;
}

+ (void)changeBadgeValueBy:(NSInteger)value forItem:(CLSourceListItem *)item {
	[item setBadgeValue:([item badgeValue] + value)];
	
	if ([item badgeValue] < 0) {
		[item setBadgeValue:0];
	}
}

+ (void)changeBadgeValuesBy:(NSInteger)value forAncestorsOfItem:(CLSourceListItem *)item {
	
	if (value == 0) {
		return;
	}
	
	CLSourceListFolder *ancestor = nil;
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		ancestor = [(CLSourceListFeed *)item enclosingFolderReference];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		ancestor = [(CLSourceListFolder *)item parentFolderReference];
	}
	
	if (ancestor != nil) {
		[ancestor setBadgeValue:([ancestor badgeValue] + value)];
		[SyndicationAppDelegate changeBadgeValuesBy:value forAncestorsOfItem:ancestor];
	}
}

+ (void)clearBadgeValuesForItemAndDescendents:(CLSourceListItem *)item {
	[item setBadgeValue:0];
	
	for (CLSourceListItem *child in [item children]) {
		[SyndicationAppDelegate clearBadgeValuesForItemAndDescendents:child];
	}
}

+ (void)addToTimelineUnreadItemsDict:(CLTimelineViewItem *)timelineViewItem {
	if (timelineViewItem != nil) {
		NSInteger postDbId = [timelineViewItem postDbId];
		NSNumber *key = [NSNumber numberWithInteger:postDbId];
		NSMutableArray *unreadItems = [timelineUnreadItemsDict objectForKey:key];
		
		if (unreadItems == nil) {
			unreadItems = [NSMutableArray arrayWithCapacity:10];
			[timelineUnreadItemsDict setObject:unreadItems forKey:key];
		}
		
		[unreadItems addObject:timelineViewItem];
	}
}

+ (void)removeFromTimelineUnreadItemsDict:(CLTimelineViewItem *)timelineViewItem {
	if (timelineViewItem != nil) {
		NSInteger postDbId = [timelineViewItem postDbId];
		NSNumber *key = [NSNumber numberWithInteger:postDbId];
		NSMutableArray *unreadItems = [timelineUnreadItemsDict objectForKey:key];
		
		if (unreadItems != nil) {
			[unreadItems removeObject:timelineViewItem];
		}
	}
}

+ (NSString *)miscellaneousValueForKey:(NSString *)key {
	
	if (key == nil) {
		return nil;
	}
	
	NSString *value = nil;
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	FMResultSet *rs = [db executeQuery:@"SELECT * FROM miscellaneous WHERE Key=?", key];
	
	if ([rs next]) {
		value = [rs stringForColumn:@"Value"];
	}
	
	[rs close];
	[db close];
	
	return value;
}

+ (void)miscellaneousSetValue:(NSString *)value forKey:(NSString *)key {
	
	if (key == nil) {
		return;
	}
	
	BOOL alreadyInDB = NO;
	
	if ([SyndicationAppDelegate miscellaneousValueForKey:key] != nil) {
		alreadyInDB = YES;
	}
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	if (alreadyInDB) {
		[db executeUpdate:@"UPDATE miscellaneous SET Value=? WHERE Key=?", value, key];
	} else {
		[db executeUpdate:@"INSERT INTO miscellaneous (Value, Key) VALUES (?, ?)", value, key];
	}
	
	[db close];
}


- (id)init {
	self = [super init];
	
	if (self != nil) {
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidBecomeKey:) name:NSWindowDidBecomeKeyNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidResignKey:) name:NSWindowDidResignKeyNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowIsClosing:) name:NSWindowWillCloseNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowWillStartLiveResize:) name:NSWindowWillStartLiveResizeNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidEndLiveResize:) name:NSWindowDidEndLiveResizeNotification object:nil];
		
		// register handler for feed:// urls
		NSAppleEventManager *em = [NSAppleEventManager sharedAppleEventManager];
		[em setEventHandler:self andSelector:@selector(handleFeedEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
		
		[self setFeedLookupDict:[NSMutableDictionary dictionary]];
		[self setOperationQueue:[[[NSOperationQueue alloc] init] autorelease]];
		[operationQueue setMaxConcurrentOperationCount:2];
		[self setFeedsToSync:[NSMutableArray array]];
		[self setFeedRequests:[NSMutableArray array]];
		[self setRequestQueue:[NSMutableArray array]];
		[self setRequestInProgress:NO];
		[self setIconRefreshTimers:[NSMutableArray array]];
		[self setActivityViewFeeds:[NSMutableArray array]];
		[self setPreferenceCheckForNewArticles:-1];
		[self setPreferenceRemoveArticles:-1];
		[self setPreferenceMarkArticlesAsRead:-1];
		[self setPreferenceDisplayUnreadCountInDock:NO];
		[self setIsFirstWindow:YES];
	}
	
	return self;
}

- (void)dealloc {
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[operationQueue cancelAllOperations];
	
	if ([feedSyncTimer isValid]) {
		[feedSyncTimer invalidate];
	}
	
	for (CLTimer *timer in iconRefreshTimers) {
		if ([timer isValid]) {
			[timer invalidate];
		}
	}
	
	[subscriptionList release];
	[feedLookupDict release];
	[operationQueue release];
	[feedSyncTimer release];
	[feedsToSync release];
	[feedRequests release];
	[requestQueue release];
	[iconRefreshTimers release];
	[activityViewFeeds release];
	[windowControllers release];
	[preferencesWindow release]; // release top level object of preferences nib file
	[windowForUpdate release];
	[feedEventString release];
	
	[super dealloc];
}

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification {
	
	[[NSFileManager defaultManager] clCopyLiteDirectoryIfItExistsAndRegularDirectoryDoesnt];
	
	NSInteger thirtyMinutes = TIME_INTERVAL_MINUTE * 30;
	NSInteger oneYear = TIME_INTERVAL_YEAR;
	NSInteger oneMonth = TIME_INTERVAL_MONTH;
	
	NSDictionary *registrationDefaults = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:thirtyMinutes], PREFERENCES_CHECK_FOR_NEW_ARTICLES_KEY,
																					[NSNumber numberWithInteger:oneYear], PREFERENCES_REMOVE_ARTICLES_KEY,
																					[NSNumber numberWithInteger:oneMonth], PREFERENCES_MARK_ARTICLES_AS_READ_KEY,
																					[NSNumber numberWithBool:YES], PREFERENCES_DISPLAY_UNREAD_COUNT_IN_DOCK_KEY, nil]; 
	[[NSUserDefaults standardUserDefaults] registerDefaults:registrationDefaults];
	
	NSString *headlineFontName = @"HelveticaNeue-Medium";
	NSString *databaseString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_HEADLINE_FONT_NAME];
	
	if (databaseString != nil) {
		headlineFontName = databaseString;
	}
	
	[self setPreferenceHeadlineFontName:headlineFontName];
	
	CGFloat headlineFontSize = 11.0f;
	databaseString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_HEADLINE_FONT_SIZE];
	
	if (databaseString != nil) {
		headlineFontSize = [databaseString floatValue];
	}
	
	[self setPreferenceHeadlineFontSize:headlineFontSize];
	
	NSString *bodyFontName = @"HelveticaNeue";
	databaseString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_BODY_FONT_NAME];
	
	if (databaseString != nil) {
		bodyFontName = databaseString;
	}
	
	[self setPreferenceBodyFontName:bodyFontName];
	
	CGFloat bodyFontSize = 10.0f;
	databaseString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_BODY_FONT_SIZE];
	
	if (databaseString != nil) {
		bodyFontSize = [databaseString floatValue];
	}
	
	[self setPreferenceBodyFontSize:bodyFontSize];
	
	NSURLCache *sharedCache = [[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:0 diskPath:nil];
	[NSURLCache setSharedURLCache:sharedCache];
	[sharedCache release];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	
#ifndef NDEBUG
	if (getenv("NSZombieEnabled") || getenv("NSAutoreleaseFreedObjectCheckEnabled")) {
		[CLErrorHelper createAndDisplayError:@"NSZombieEnabled"];
	}
#endif
	
	[self loadFromDatabase];
	[self sortSourceList];
	
	[self readPreferencesAndUpdate];
	
	NSString *firstLaunchString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_FIRST_LAUNCH];
	
	if (firstLaunchString == nil) {
		//[welcomeWindow center];
		//[welcomeWindow makeKeyAndOrderFront:self];
		
		//[self setShowingWelcomeWindow:YES];
	}
	
	[SyndicationAppDelegate miscellaneousSetValue:@"0" forKey:MISCELLANEOUS_FIRST_LAUNCH];
	
	[self setWindowControllers:[NSMutableArray array]];
	
	[self newWindow];
	
	[self updateSubscriptionsMenu];
	
	if (firstLaunchString == nil) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert addButtonWithTitle:@"OK"];
		[alert addButtonWithTitle:@"Cancel"];
		[alert setMessageText:@"Would you like to add some sample subscriptions to get started?"];
		[alert setAlertStyle:NSInformationalAlertStyle];
		
		if ([alert runModal] == NSAlertFirstButtonReturn) {
			[self addSubscriptionForUrlString:@"http://creativecommons.org/weblog/feed/rss" withTitle:@"Creative Commons" toFolder:nil refreshImmediately:NO];
			[self addSubscriptionForUrlString:@"http://blog.flickr.net/en/feed/atom/" withTitle:@"Flickr Blog" toFolder:nil refreshImmediately:NO];
			[self addSubscriptionForUrlString:@"http://blog.makezine.com/index.xml" withTitle:@"Make:" toFolder:nil refreshImmediately:NO];
		}
	}
	
	[CLTimer scheduledTimerWithTimeInterval:(TIME_INTERVAL_MINUTE * 10) target:self selector:@selector(queueDeleteHiddenRequest) userInfo:nil repeats:YES];
	[CLTimer scheduledTimerWithTimeInterval:(TIME_INTERVAL_MINUTE * 75) target:self selector:@selector(removeOldArticles) userInfo:nil repeats:YES];
	[CLTimer scheduledTimerWithTimeInterval:(TIME_INTERVAL_MINUTE * 80) target:self selector:@selector(markArticlesAsRead) userInfo:nil repeats:YES];
	[CLTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(startFeedRequests) userInfo:nil repeats:YES];
	[CLTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(startRequestIfNoneInProgress) userInfo:nil repeats:YES];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(defaultsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
	
	if (feedEventString != nil) {
		[self addSubscriptionForUrlString:feedEventString withTitle:nil toFolder:nil refreshImmediately:YES];
		[self setFeedEventString:nil];
	}
	
	[self setHasFinishedLaunching:YES];
}

- (BOOL)tableExists:(NSString *)tableName inDb:(FMDatabase *)db {
	BOOL returnBool;
	tableName = [tableName lowercaseString];
	
	FMResultSet *rs = [db executeQuery:@"select [sql] from sqlite_master where [type] = 'table' and lower(name) = ?", tableName];
	returnBool = [rs next];
	[rs close];
	
	return returnBool;
}

- (void)runDatabaseUpdateOnBackgroundThread:(NSString *)queryString, ... {
	NSMutableArray *query = [NSMutableArray array];
	[query addObject:queryString];

	va_list args;
	va_start(args, queryString);

	for (id arg = va_arg(args, id); arg != nil; arg = va_arg(args, id)) {
		[query addObject:arg];
	}

	va_end(args);

	[self runDatabaseUpdatesOnBackgroundThread:[NSArray arrayWithObject:query]];
}

- (void)runDatabaseUpdatesOnBackgroundThread:(NSArray *)queries {
	CLDatabaseUpdateOperation *dbOp = [[CLDatabaseUpdateOperation alloc] init];
	[dbOp setQueries:queries];
	[dbOp setDelegate:self];

	[operationQueue addOperation:dbOp];
	[dbOp release];
}

- (void)loadFromDatabase {
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	[self setSubscriptionList:[NSMutableArray array]];
	
	if ([self tableExists:@"enclosure" inDb:db] == NO) {
		[db executeUpdate:@"CREATE TABLE enclosure (Id INTEGER PRIMARY KEY, PostId INTEGER, Url TEXT)"];
	}
	
	if ([self tableExists:@"feed" inDb:db] == NO) {
		[db executeUpdate:@"CREATE TABLE feed (Id INTEGER PRIMARY KEY, FolderId INTEGER, Url TEXT, Title TEXT, Icon BLOB, LastRefreshed REAL, IconLastRefreshed REAL, WebsiteLink TEXT, IsHidden INTEGER NOT NULL DEFAULT 0, UnreadCount INTEGER NOT NULL DEFAULT 0, LastSyncPosts BLOB)"];
	}
	
	if ([self tableExists:@"folder" inDb:db] == NO) {
		[db executeUpdate:@"CREATE TABLE folder (Id INTEGER PRIMARY KEY, ParentId INTEGER, Path TEXT, Title TEXT)"];
	}
	
	if ([self tableExists:@"miscellaneous" inDb:db] == NO) {
		[db executeUpdate:@"CREATE TABLE miscellaneous (Id INTEGER PRIMARY KEY, Key TEXT, Value TEXT)"];
	}
	
	if ([self tableExists:@"post" inDb:db] == NO) {
		[db executeUpdate:@"CREATE TABLE post (Id INTEGER PRIMARY KEY, FeedId INTEGER, Guid TEXT, Title TEXT, Link TEXT, Published INTEGER, Received INTEGER, Author TEXT, Content TEXT, PlainTextContent TEXT, IsRead INTEGER NOT NULL DEFAULT 0, HasEnclosures INTEGER NOT NULL DEFAULT 0, IsHidden INTEGER NOT NULL DEFAULT 0, IsStarred INTEGER NOT NULL DEFAULT 0)"];
	}
	
	[self recursivelyLoadChildrenOf:nil usingDatabaseHandle:db];
	
	[db close];
	
	NSString *versionId = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	[SyndicationAppDelegate miscellaneousSetValue:versionId forKey:MISCELLANEOUS_DATABASE_VERSION];
}

- (void)recursivelyLoadChildrenOf:(CLSourceListFolder *)folder usingDatabaseHandle:(FMDatabase *)db {
	
	FMResultSet *rs;
	
	if (folder == nil) {
		rs = [db executeQuery:@"SELECT * FROM folder WHERE folder.ParentId IS NULL"];
	} else {
		rs = [db executeQuery:@"SELECT * FROM folder WHERE folder.ParentId=?", [NSNumber numberWithInteger:[folder dbId]]];
	}
	
	while ([rs next]) {
		CLSourceListFolder *newFolder = [[CLSourceListFolder alloc] init];
		[newFolder setDbId:[rs longForColumn:@"Id"]];
		[newFolder setPath:[rs stringForColumn:@"Path"]];
		[newFolder setTitle:[rs stringForColumn:@"Title"]];
		
		if (folder == nil) {
			[subscriptionList addObject:newFolder];
		} else {
			[[folder children] addObject:newFolder];
			[newFolder setParentFolderReference:folder];
		}
		
		[self recursivelyLoadChildrenOf:newFolder usingDatabaseHandle:db];
		
		[newFolder release];
	}
	
	[rs close];
	rs = nil;
	
	if (folder == nil) {
		rs = [db executeQuery:@"SELECT * FROM feed WHERE feed.FolderId IS NULL"];
	} else {
		rs = [db executeQuery:@"SELECT * FROM feed WHERE feed.FolderId=?", [NSNumber numberWithInteger:[folder dbId]]];
	}
	
	while ([rs next]) {
		CLSourceListFeed *feed = [[CLSourceListFeed alloc] initWithResultSet:rs];
		
		BOOL isHidden = [rs boolForColumn:@"IsHidden"];
		
		if (isHidden == NO) {
			
			if (folder == nil) {
				[subscriptionList addObject:feed];
			} else {
				[[folder children] addObject:feed];
				[feed setEnclosingFolderReference:folder];
			}
			
			// refresh the icon (if we have the link for this feed)
			if ([feed websiteLink] != nil && [[feed websiteLink] length] > 0) {
				NSTimeInterval iconRefreshTimeLapsed = 0.0;
				NSTimeInterval iconRefreshDelay = 0.0;
				NSTimeInterval minRefreshDelay = (TIME_INTERVAL_MINUTE * 10);
				
				if ([feed iconLastRefreshed] != nil) {
					iconRefreshTimeLapsed = [[NSDate date] timeIntervalSinceDate:[feed iconLastRefreshed]];
				}
				
				if ([feed iconLastRefreshed] == nil || iconRefreshTimeLapsed > ICON_REFRESH_INTERVAL) {
					iconRefreshDelay = minRefreshDelay;
				} else {
					iconRefreshDelay = ICON_REFRESH_INTERVAL - iconRefreshTimeLapsed;
				}
				
				if (iconRefreshDelay < minRefreshDelay) {
					iconRefreshDelay = minRefreshDelay;
				}
				
				CLTimer *iconTimer = [CLTimer scheduledTimerWithTimeInterval:iconRefreshDelay target:self selector:@selector(timeToAddFeedToIconQueue:) userInfo:feed repeats:NO];
				[iconRefreshTimers addObject:iconTimer];
			}
		}
		
		[feedLookupDict setObject:feed forKey:[NSNumber numberWithInteger:[feed dbId]]];
		
		[feed release];
	}
	
	[rs close];
}

- (void)updateFeedSyncStatus {
	
	if (feedSyncTimer != nil) {
		if ([feedSyncTimer isValid]) {
			[feedSyncTimer invalidate];
		}
		
		[self setFeedSyncTimer:nil];
	}
	
	if (preferenceCheckForNewArticles > 0) {
			
		NSString *lastSyncString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_LAST_FEED_SYNC_KEY];
		NSInteger refreshTimeLapsed = 0;
		
		if (lastSyncString != nil) {
			NSInteger lastSyncInteger = [lastSyncString integerValue];
			NSDate *lastSync = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)lastSyncInteger];
			refreshTimeLapsed = (NSInteger)[[NSDate date] timeIntervalSinceDate:lastSync];
		}
		
		NSInteger delay = 0;
		
		if (lastSyncString != nil && refreshTimeLapsed < preferenceCheckForNewArticles) {
			delay = (preferenceCheckForNewArticles - refreshTimeLapsed);
		}
		
		// note that we use a timer even when we want to start the refresh right away - this is because timeToSyncFeeds will also start the next timer
		CLTimer *syncTimer = [CLTimer scheduledTimerWithTimeInterval:delay target:self selector:@selector(timeToSyncFeeds:) userInfo:nil repeats:NO];
		[self setFeedSyncTimer:syncTimer];
	}
}

- (void)queueAllFeedsSyncRequest {
	CLRequest *request = [[CLRequest alloc] init];
	[request setRequestType:CLRequestAllFeedsSync];
	
	[requestQueue addObject:request];
	[request release];
	
	[self startRequestIfNoneInProgress];
}

- (void)queueSyncRequestForSpecificFeeds:(NSMutableArray *)feeds {
	
	if (feeds == nil || [feeds count] == 0) {
		return;
	}
	
	CLRequest *request = [[CLRequest alloc] init];
	[request setRequestType:CLRequestSpecificFeedsSync];
	[request setSpecificFeeds:feeds];
	
	[requestQueue addObject:request];
	[request release];
	
	[self startRequestIfNoneInProgress];
}

- (void)queueDeleteHiddenRequest {
	
	CLRequest *request = [[CLRequest alloc] init];
	[request setRequestType:CLRequestDeleteHidden];
	
	[requestQueue addObject:request];
	[request release];
	
	[self startRequestIfNoneInProgress];
}

- (void)startRequestIfNoneInProgress {
	if ([feedRequests count] == 0 && [feedsToSync count] == 0 && [operationQueue operationCount] == 0) {
		[self setRequestInProgress:NO];
		[self setNumberOfActiveParseOps:0];
	}
	
	while (requestInProgress == NO && [requestQueue count] > 0) {
		
		CLRequest *request = [[[requestQueue objectAtIndex:0] retain] autorelease];
		[requestQueue removeObjectAtIndex:0];
		
		if ([request requestType] == CLRequestAllFeedsSync) {
			NSInteger timestamp = (NSInteger)[[NSDate date] timeIntervalSince1970];
			NSString *timestampString = [[NSNumber numberWithInteger:timestamp] stringValue];
			[SyndicationAppDelegate miscellaneousSetValue:timestampString forKey:MISCELLANEOUS_LAST_FEED_SYNC_KEY];
			
			if ([subscriptionList count] > 0) {
				[feedsToSync addObjectsFromArray:subscriptionList];
				[self startFeedRequests];
				
				[self setRequestInProgress:YES];
				[self setActiveRequestType:[request requestType]];
			}
			
		} else if ([request requestType] == CLRequestSpecificFeedsSync) {
			
			[feedsToSync addObjectsFromArray:[request specificFeeds]];
			[self startFeedRequests];
			
			[self setRequestInProgress:YES];
			[self setActiveRequestType:[request requestType]];
			
		} else if ([request requestType] == CLRequestDeleteHidden) {
			
			[self queueDeleteHiddenOperation];
			
			[self setRequestInProgress:YES];
			[self setActiveRequestType:[request requestType]];
			
		} else {
#ifndef NDEBUG
			[NSException raise:@"error" format:@"can't handle item"];
#endif
		}
	}
}

- (void)startFeedRequests {
	while ([feedsToSync count] > 0 && ([feedRequests count] + numberOfActiveParseOps) < MAX_CONCURRENT_REQUESTS) {
		
		CLSourceListFeed *feed = [feedsToSync objectAtIndex:0];
		[feedsToSync removeObjectAtIndex:0];
		
		[activityViewFeeds addObject:feed];
		[self refreshAllActivityViews];
		
		CLFeedRequest *feedRequest = [[CLFeedRequest alloc] init];
		[feedRequest setFeed:feed];
		[feedRequest setDelegate:self];
		
		[feedRequests addObject:feedRequest]; // needs to be before call to startConnection
		[feedRequest release];
		
		[feedRequest startConnection];
	}
}

- (void)feedRequest:(CLFeedRequest *)feedRequest didFinishWithData:(NSData *)data encoding:(NSStringEncoding)encoding {
	[[feedRequest retain] autorelease];
	[feedRequests removeObject:feedRequest];
	
	if (data != nil) {
		CLFeedParserOperation *parserOp = [[CLFeedParserOperation alloc] init];
		[parserOp setDelegate:self];
		[parserOp setFeed:[feedRequest feed]];
		[parserOp setData:data];
		[parserOp setEncoding:encoding];
		
		[operationQueue addOperation:parserOp];
		[parserOp release];
		
		[self setNumberOfActiveParseOps:(numberOfActiveParseOps+1)];
		
	} else {
		[activityViewFeeds removeObject:[feedRequest feed]];
		[self refreshAllActivityViews];
		
		if ([feedRequests count] == 0 && [feedsToSync count] == 0 && numberOfActiveParseOps == 0) {
			[self setRequestInProgress:NO];
			[self startRequestIfNoneInProgress];
		} else if ([feedRequests count] == 0) {
			[self startFeedRequests];
		}
	}
}

- (void)queueIconRefreshOperationFor:(CLSourceListFeed *)feed {
	CLIconRefreshOperation *iconOp = [[CLIconRefreshOperation alloc] init];
	[iconOp setFeed:feed];
	[iconOp setDelegate:self];
	
	[operationQueue addOperation:iconOp];
	[iconOp release];
}

- (void)queueDeleteHiddenOperation {
	CLDeleteHiddenOperation *deleteOp = [[CLDeleteHiddenOperation alloc] init];
	[deleteOp setFeeds:subscriptionList];
	[deleteOp setDelegate:self];
	
	[operationQueue addOperation:deleteOp];
	[deleteOp release];
}

- (void)cancelAllActivityFor:(CLSourceListItem *)item {
	if (item != nil) {
		
		[self cancelAnyTimersIn:iconRefreshTimers forItem:item];
		
		// cancel any active operations
		NSArray *operationList = [operationQueue operations];
		
		CLSourceListFeed *operationFeed;
		
		for (NSOperation *operation in operationList) {
			operationFeed = nil;
			
			if ([operation isKindOfClass:[CLIconRefreshOperation class]]) {
				operationFeed = [(CLIconRefreshOperation *)operation feed];
			}
			
			if (operationFeed != nil) {
				if ([item isKindOfClass:[CLSourceListFeed class]]) {
					CLSourceListFeed *feed = (CLSourceListFeed *)item;
					
					if ([feed dbId] == [operationFeed dbId]) {
						[operation cancel];
					}
				} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
					CLSourceListFolder *folder = (CLSourceListFolder *)item;
					
					if ([SyndicationAppDelegate isSourceListItem:operationFeed descendentOf:folder]) {
						[operation cancel];
					}
				}
			}
		}
	}
}

- (void)cancelAnyTimersIn:(NSMutableArray *)timerList forItem:(CLSourceListItem *)item {
	
	CLSourceListFeed *timerFeed;
	NSMutableArray *timersToRemove = [NSMutableArray array];
	
	for (CLTimer *timer in timerList) {
		if ([timer isValid]) {
			timerFeed = (CLSourceListFeed *)[timer userInfo];
			
			if ([item isKindOfClass:[CLSourceListFeed class]]) {
				CLSourceListFeed *feed = (CLSourceListFeed *)item;
				
				if ([feed dbId] == [timerFeed dbId]) {
					[timer invalidate];
					[timersToRemove addObject:timer];
				}
			} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
				CLSourceListFolder *folder = (CLSourceListFolder *)item;
				
				if ([SyndicationAppDelegate isSourceListItem:timerFeed descendentOf:folder]) {
					[timer invalidate];
					[timersToRemove addObject:timer];
				}
			}
		}
	}
	
	for (CLTimer *timer in timersToRemove) {
		[timerList removeObject:timer];
	}
}

- (void)processNewPosts:(NSArray *)newPosts forFeed:(CLSourceListFeed *)feed {
	
	if ([newPosts count] > 0) {
		
		NSArray *reverseNewItems = [[newPosts reverseObjectEnumerator] allObjects];
		
		// add them to the db
		FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
		
		if (![db open]) {
			[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
		}
		
		BOOL feedStillExistsInDatabase = NO;
		BOOL isHiddenFeed = NO;
		
		FMResultSet *rs = [db executeQuery:@"SELECT * FROM feed WHERE Id=?", [NSNumber numberWithInteger:[feed dbId]]];
		
		if ([rs next]) {
			feedStillExistsInDatabase = YES;
			isHiddenFeed = [rs boolForColumn:@"IsHidden"];
		}
		
		[rs close];
		[db close];
		
		if (feedStillExistsInDatabase) {
			
			db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
			
			if (![db open]) {
				[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
			}
			
			NSDate *now;
			
			[db beginTransaction];
			
			for (CLPost *post in reverseNewItems) {
				
				now = [NSDate date];
				
				if ([post published] == nil) {
					[post setPublished:now];
				}
				
				[post setReceived:now];
				
				BOOL hasEnclosures = NO;
				
				if ([[post enclosures] count] > 0) {
					hasEnclosures = YES;
				}
				
				[db executeUpdate:@"INSERT INTO post (FeedId, Guid, Title, Link, Published, Received, Author, Content, PlainTextContent, IsRead, HasEnclosures) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [NSNumber numberWithInteger:[post feedDbId]], [post guid], [post title], [post link], [post published], [post received], [post author], [post content], [post plainTextContent], [NSNumber numberWithBool:[post isRead]], [NSNumber numberWithBool:hasEnclosures]];
				NSInteger insertId = [db lastInsertRowId];
				[post setDbId:insertId];
				
				for (NSString *enclosure in [post enclosures]) {
					[db executeUpdate:@"INSERT INTO enclosure (PostId, Url) VALUES (?, ?)", [NSNumber numberWithInteger:insertId], enclosure];
				}
			}
			
			[self runDatabaseUpdateOnBackgroundThread:UNREAD_COUNT_QUERY, [NSNumber numberWithInteger:[feed dbId]], [NSNumber numberWithInteger:[feed dbId]], nil];
			
			[db commit];
			
			[db close];
			
			if (isHiddenFeed == NO) {
				[self addPostsToAllWindows:reverseNewItems forFeed:feed orNewItems:YES orStarredItems:NO];
			}
		}
	}
	
	[self updateMenuItems];
}

- (void)addPostsToAllWindows:(NSArray *)posts forFeed:(CLSourceListFeed *)feed orNewItems:(BOOL)newItems orStarredItems:(BOOL)starredItems {
	
	for (CLWindowController *windowController in windowControllers) {
		
		for (CLTabViewItem *tabViewItem in [[windowController tabView] tabViewItems]) {
			
			if (([tabViewItem sourceListItem] == feed || [SyndicationAppDelegate isSourceListItem:feed descendentOf:[tabViewItem sourceListItem]]) ||
				([tabViewItem sourceListItem] == [windowController sourceListNewItems] && newItems == YES) ||
				([tabViewItem sourceListItem] == [windowController sourceListStarredItems] && starredItems == YES)) {
				
				NSInteger postsAdded = 0;
				NSInteger postsSkippedAtTopCount = 0;
				BOOL postsSkippedAtBottom = NO;
				BOOL isOnlyUnreadItems = ([tabViewItem sourceListItem] == [windowController sourceListNewItems]);
				
				if ([tabViewItem tabType] == CLTimelineType) {
					CLTimelineView *timeline = [tabViewItem timelineView];
					NSClipView *clipView = (NSClipView *)[timeline superview];
					NSInteger originalPostCount = [[timeline timelineViewItems] count];
					NSInteger postsPerScreen = [windowController numberOfTimelineViewItemsPerScreenOfClipView:clipView];
					NSInteger threshold = (postsPerScreen * TIMELINE_UNLOAD_MULTIPLIER);
					
					if (originalPostCount > 0) {
						for (CLPost *post in posts) {
							if ([post isRead] == NO || isOnlyUnreadItems == NO) {
								
								CLTimelineViewItem *selectedTimelineViewItem = [timeline selectedItem];
								NSInteger insertLocation = PROCESS_NEW_POSTS_SKIPPED_AT_BOTTOM;
								
								if ([tabViewItem sourceListItem] != [windowController sourceListStarredItems]) {
										
									insertLocation = 0;
									
								} else {
									
									NSInteger i = 0;
									
									for (CLTimelineViewItem *item in [timeline timelineViewItems]) {
										if ([item postDbId] < [post dbId]) {
											insertLocation = i;
											break;
										}
										
										i++;
									}
								}
								
								if (insertLocation == 0 && selectedTimelineViewItem != nil) {
									NSInteger numberOfPostsBeforeSelectedItem = [[timeline timelineViewItems] indexOfObject:selectedTimelineViewItem];
									
									if (numberOfPostsBeforeSelectedItem >= threshold) {
										insertLocation = PROCESS_NEW_POSTS_SKIPPED_AT_TOP;
									}
								}
								
								if (insertLocation == 0 && [timeline postsMissingFromTopCount] > 0) {
									insertLocation = PROCESS_NEW_POSTS_SKIPPED_AT_TOP;
								}
								
								if (insertLocation >= 0) {
									[windowController addPost:post toTimeline:timeline atIndex:insertLocation];
									postsAdded++;
								} else if (insertLocation == PROCESS_NEW_POSTS_SKIPPED_AT_TOP) {
									postsSkippedAtTopCount++;
								} else if (insertLocation == PROCESS_NEW_POSTS_SKIPPED_AT_BOTTOM) {
									postsSkippedAtBottom = YES;
								}
							}
							
							if (postsAdded > 0 && (postsAdded % 5) == 0) {
								[timeline updateSubviewRects];
								[timeline setNeedsDisplay:YES];
							}
						}
						
						if (postsSkippedAtTopCount > 0) {
							[timeline setPostsMissingFromTopCount:([timeline postsMissingFromTopCount] + postsSkippedAtTopCount)];
						}
						
						if (postsSkippedAtBottom) {
							[timeline setPostsMissingFromBottom:YES];
						}
						
						if (postsAdded > 0) {
							[timeline updateSubviewRects];
							[timeline setNeedsDisplay:YES];
						}
						
						[windowController checkIfTimelineNeedsToUnloadContent:timeline];
						[windowController checkIfTimelineNeedsToLoadMoreContent:timeline];
					} else {
						[windowController reloadContentForTab:tabViewItem];
					}
					
				} else if ([tabViewItem tabType] == CLClassicType) {
					
					CLClassicView *classicView = [tabViewItem classicView];
					NSInteger selectedRow = [[classicView tableView] selectedRow];
					CGFloat rowHeight = [[classicView tableView] rowHeight] + [[classicView tableView] intercellSpacing].height;
					
					NSClipView *clipView = (NSClipView *)[[classicView tableView] superview];
					NSScrollView *scrollView = (NSScrollView *)[clipView superview];
					CGFloat scrollX = [scrollView documentVisibleRect].origin.x;
					CGFloat oldScrollY = [scrollView documentVisibleRect].origin.y;
					CGFloat scrollY = oldScrollY;
					
					for (CLPost *post in posts) {
						if ([post isRead] == NO || isOnlyUnreadItems == NO) {
							NSInteger insertLocation = PROCESS_NEW_POSTS_SKIPPED_AT_BOTTOM;
							
							if ([tabViewItem sourceListItem] != [windowController sourceListStarredItems]) {
								insertLocation = 0;
								[[classicView posts] insertObject:post atIndex:insertLocation];
							} else {
								NSInteger i = 0;
								
								for (CLPost *item in [classicView posts]) {
									if ([item dbId] < [post dbId]) {
										insertLocation = i;
										break;
									}
									
									i++;
								}
								
								if ([[classicView posts] count] == 0 && [classicView postsMissingFromBottom] == NO) {
									insertLocation = 0;
								}
								
								if (insertLocation >= 0) {
									[[classicView posts] insertObject:post atIndex:insertLocation];
								} else if (insertLocation == PROCESS_NEW_POSTS_SKIPPED_AT_BOTTOM) {
									postsSkippedAtBottom = YES;
								}
							}
							
							if ([post isRead] == NO) {
								NSNumber *key = [NSNumber numberWithInteger:[post dbId]];
								[[classicView unreadItemsDict] setObject:post forKey:key];
							}
							
							if (selectedRow >= 0 && insertLocation >= 0 && insertLocation <= selectedRow) {
								selectedRow++;
							}
							
							if (insertLocation >= 0 && (insertLocation * rowHeight) <= scrollY) {
								scrollY += rowHeight;
							}
							
							postsAdded++;
						}
					}
					
					if (postsSkippedAtBottom) {
						[classicView setPostsMissingFromBottom:YES];
					}
					
					if (postsAdded > 0) {
						
						BOOL alreadyUpdatedSelection = NO;
						
						if (selectedRow >= 0 && selectedRow < ((NSInteger)[[classicView posts] count] - postsAdded)) {
							[[classicView tableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedRow] byExtendingSelection:NO];
							alreadyUpdatedSelection = YES;
						} else {
							[classicView setShouldIgnoreSelectionChange:YES];
							[[classicView tableView] deselectAll:self];
						}
						
						if (scrollY != oldScrollY) {
							[scrollView clScrollInstantlyTo:NSMakePoint(scrollX, scrollY)];
						}
						
						[[classicView tableView] reloadData];
						[(NSView *)[classicView tableView] display];
						
						if (selectedRow >= 0 && alreadyUpdatedSelection == NO) {
							[[classicView tableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedRow] byExtendingSelection:NO];
						}
						
						if (scrollY != oldScrollY) {
							[scrollView clScrollInstantlyTo:NSMakePoint(scrollX, scrollY)];
						}
					}
					
					[windowController checkIfClassicViewNeedsToUnloadContent:classicView];
					[windowController checkIfClassicViewNeedsToLoadMoreContent:classicView];
				}
				
				[windowController updateViewVisibilityForTab:tabViewItem];
			}
		}
		
		[[windowController sourceList] setNeedsDisplay:YES];
	}
}

- (void)removeStarredPostFromAllWindows:(CLPost *)post {
	
	for (CLWindowController *windowController in windowControllers) {
		
		for (CLTabViewItem *tabViewItem in [[windowController tabView] tabViewItems]) {
			
			if ([tabViewItem sourceListItem] == [windowController sourceListStarredItems]) {
				
				if ([tabViewItem tabType] == CLTimelineType) {
					CLTimelineView *timeline = [tabViewItem timelineView];
					
					NSInteger location = -1;
					NSInteger i = 0;
					
					for (CLTimelineViewItem *timelineViewItem in [timeline timelineViewItems]) {
						if ([timelineViewItem postDbId] == [post dbId]) {
							location = i;
							break;
						}
						
						i++;
					}
					
					if (location >= 0) {
						[timeline removePostsInRange:NSMakeRange(location, 1) preserveScrollPosition:YES updateMetadata:NO];
					}
					
					[timeline updateSubviewRects];
					[timeline setNeedsDisplay:YES];
					[windowController selectItemAtTopOfTimelineView:timeline];
					
					[windowController checkIfTimelineNeedsToUnloadContent:timeline];
					[windowController checkIfTimelineNeedsToLoadMoreContent:timeline];
					
				} else if ([tabViewItem tabType] == CLClassicType) {
					
					CLClassicView *classicView = [tabViewItem classicView];
					
					NSInteger location = -1;
					NSInteger i = 0;
					
					for (CLPost *classicPost in [classicView posts]) {
						if ([classicPost dbId] == [post dbId]) {
							location = i;
							break;
						}
						
						i++;
					}
					
					if (location >= 0) {
						[classicView removePostsInRange:NSMakeRange(location, 1) preserveScrollPosition:YES updateMetadata:NO ignoreSelection:NO];
					}
					
					[windowController checkIfClassicViewNeedsToUnloadContent:classicView];
					[windowController checkIfClassicViewNeedsToLoadMoreContent:classicView];
				}
				
				[windowController updateViewVisibilityForTab:tabViewItem];
			}
		}
	}
}

- (void)didStartOperation:(CLOperation *)op {
	
}

- (void)didFinishOperation:(CLOperation *)op {
	if ([op isKindOfClass:[CLFeedParserOperation class]]) {
		
		[activityViewFeeds removeObject:[(CLFeedParserOperation *)op feed]];
		[self refreshAllActivityViews];
		
		[self setNumberOfActiveParseOps:(numberOfActiveParseOps-1)];
		
		[self startFeedRequests];
		
	}
	
	if (requestInProgress) {
		if ([operationQueue operationCount] == 1) {
			if (activeRequestType == CLRequestAllFeedsSync || activeRequestType == CLRequestSpecificFeedsSync) {
				if ([feedRequests count] == 0 && [feedsToSync count] == 0) {
					[self setRequestInProgress:NO];
					[self startRequestIfNoneInProgress];
				}
			} else if (activeRequestType == CLRequestDeleteHidden) {
				[self setRequestInProgress:NO];
				[self startRequestIfNoneInProgress];
			}
		}
	}
}

- (void)feedParserOperationFoundNewPostsForFeed:(CLSourceListFeed *)feed {
	NSArray *postsToAddToDB = [feed postsToAddToDB];
	NSInteger numberOfUnread = 0;
	
	for (CLPost *post in postsToAddToDB) {
		if ([post isRead] == NO) {
			numberOfUnread++;
		}
	}
	
	if (numberOfUnread > 0) {
		[feed setBadgeValue:([feed badgeValue] + numberOfUnread)];
		[SyndicationAppDelegate changeBadgeValuesBy:numberOfUnread forAncestorsOfItem:feed];
		[self changeNewItemsBadgeValueBy:numberOfUnread];
	}
	
	[self processNewPosts:postsToAddToDB forFeed:feed];
}

- (void)feedParserOperationFoundTitleForFeed:(CLSourceListFeed *)feed {
	[self sourceListDidRenameItem:feed];
}

- (void)feedParserOperationFoundWebsiteLinkForFeed:(CLSourceListFeed *)feed {
	[self queueIconRefreshOperationFor:feed];
}

- (void)markIconAsRefreshedAndStartTimer:(CLSourceListFeed *)feed {
	
	[feed setIconLastRefreshed:[NSDate date]];
	
	if ([feed icon] != nil) {
		@try {
			NSData *faviconData = [NSArchiver archivedDataWithRootObject:[feed icon]];
			[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET Icon=?, IconLastRefreshed=? WHERE Id=?", faviconData, [feed iconLastRefreshed], [NSNumber numberWithInteger:[feed dbId]], nil];
		} @catch (...) {
			[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET Icon=NULL, IconLastRefreshed=? WHERE Id=?", [feed iconLastRefreshed], [NSNumber numberWithInteger:[feed dbId]], nil];
		}
	} else {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET Icon=NULL, IconLastRefreshed=? WHERE Id=?", [feed iconLastRefreshed], [NSNumber numberWithInteger:[feed dbId]], nil];
	}
	
	CLTimer *iconTimer = [CLTimer scheduledTimerWithTimeInterval:ICON_REFRESH_INTERVAL target:self selector:@selector(timeToAddFeedToIconQueue:) userInfo:feed repeats:NO];
	[iconRefreshTimers addObject:iconTimer];
}

- (void)iconRefreshOperation:(CLIconRefreshOperation *)refreshOp refreshedFeed:(CLSourceListFeed *)feed foundIcon:(NSImage *)icon {
	
	[feed setIcon:icon];
	
	for (CLWindowController *windowController in windowControllers) {
		[windowController redrawSourceListItem:feed];
		[[windowController activityView] setNeedsDisplay:YES];
	}
	
	[self markIconAsRefreshedAndStartTimer:feed];
}

- (NSInteger)dbIdForUrlString:(NSString *)urlString {
	NSInteger dbId = 0;
	
	if (urlString == nil || [urlString length] == 0) {
		return 0;
	}
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	FMResultSet *rs = [db executeQuery:@"SELECT * FROM feed WHERE Url=?", urlString];
	
	if ([rs next]) {
		dbId = [rs longForColumn:@"Id"];
	}
	
	[rs close];
	[db close];
	
	return dbId;
}

- (CLSourceListFeed *)feedForUrlString:(NSString *)urlString {
	CLSourceListFeed *feed = nil;
	NSInteger dbId = 0;
	
	dbId = [self dbIdForUrlString:urlString];
	
	if (dbId > 0) {
		feed = [self feedForDbId:dbId];
	}
	
	return feed;
}

- (void)timeToSyncFeeds:(CLTimer *)timer {
	[self queueAllFeedsSyncRequest];
	
	if (preferenceCheckForNewArticles) {
		CLTimer *syncTimer = [CLTimer scheduledTimerWithTimeInterval:preferenceCheckForNewArticles target:self selector:@selector(timeToSyncFeeds:) userInfo:nil repeats:NO];
		[self setFeedSyncTimer:syncTimer];
	}
}

- (void)timeToAddFeedToIconQueue:(CLTimer *)timer {
	CLSourceListFeed *feed = [timer userInfo];
	[self queueIconRefreshOperationFor:feed];
	[iconRefreshTimers removeObject:timer];
}

- (CLWindowController *)newWindow {
	CLWindowController *windowController = [[[CLWindowController alloc] init] autorelease];
	[windowControllers addObject:windowController];
	[windowController setSubscriptionList:subscriptionList];
	[windowController setDelegate:self];
	[windowController showWindow:self];
	
	[[windowController activityView] setFeeds:activityViewFeeds];
	[[windowController activityView] setNeedsDisplay:YES];
	
	if (isFirstWindow) {
		NSUInteger numUnread = [windowController updateBadgeValuesFor:subscriptionList];
		[self changeNewItemsBadgeValueBy:numUnread];
		[self setIsFirstWindow:NO];
	} else {
		[[windowController sourceListNewItems] setBadgeValue:totalUnread];
	}
	
	CLViewMode theViewMode = CLTimelineViewMode;
	NSString *viewModeString = [SyndicationAppDelegate miscellaneousValueForKey:MISCELLANEOUS_VIEW_MODE];
	
	if (viewModeString != nil) {
		NSInteger viewModeInteger = [viewModeString integerValue];
		
		if (viewModeInteger == CLClassicViewMode) {
			theViewMode = CLClassicViewMode;
		} else if (viewModeInteger == CLTimelineViewMode) {
			theViewMode = CLTimelineViewMode;
		}
	}
	
	[windowController setViewMode:theViewMode];
	
	if (theViewMode == CLTimelineViewMode) {
		[[windowController viewSegmentedControl] setSelectedSegment:0];
	} else if (theViewMode == CLClassicViewMode) {
		[[windowController viewSegmentedControl] setSelectedSegment:1];
	}
	
	[[windowController sourceList] selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
	
	[self updateMenuItems];
	
	return windowController;
}

- (void)closeAllTabsForSourceListItem:(CLSourceListItem *)subscription {
	for (CLWindowController *windowController in windowControllers) {
		if ([subscription isKindOfClass:[CLSourceListFeed class]]) {
			[windowController closeAllTabsForFeed:(CLSourceListFeed *)subscription];
		} else if ([subscription isKindOfClass:[CLSourceListFolder class]]) {
			[windowController closeAllTabsForFolderOrDescendent:(CLSourceListFolder *)subscription];
		}
	}
}

- (void)markPostWithDbIdAsRead:(NSInteger)dbId {
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	FMResultSet *rs = [db executeQuery:@"SELECT * FROM post WHERE Id=?", [NSNumber numberWithInteger:dbId]];
	
	NSInteger feedId = 0;
	
	if ([rs next]) {
		feedId = [rs longForColumn:@"FeedId"];
	}
	
	[rs close];
	[db close];
	
    NSArray *queries = [NSArray arrayWithObjects:
                        [NSArray arrayWithObjects:@"UPDATE post SET IsRead=1 WHERE Id=?", [NSNumber numberWithInteger:dbId], nil],
                        [NSArray arrayWithObjects:UNREAD_COUNT_QUERY, [NSNumber numberWithInteger:feedId], [NSNumber numberWithInteger:feedId], nil],
                        nil];
    
	[self runDatabaseUpdatesOnBackgroundThread:queries];
	
	CLSourceListFeed *feed = [self feedForDbId:feedId];
	
	[SyndicationAppDelegate changeBadgeValueBy:-1 forItem:feed];
	[SyndicationAppDelegate changeBadgeValuesBy:-1 forAncestorsOfItem:feed];
	
	[self changeNewItemsBadgeValueBy:-1];
	[self sourceListDidChange];
	
	[self markViewItemsAsReadForPostDbId:dbId];
}

- (void)markViewItemsAsReadForPostDbId:(NSInteger)postDbId {
	if (postDbId > 0) {
		
		// timelines
		NSNumber *key = [NSNumber numberWithInteger:postDbId];
		NSMutableArray *unreadItems = [timelineUnreadItemsDict objectForKey:key];
		
		if (unreadItems != nil) {
			for (CLTimelineViewItem *timelineViewItem in unreadItems) {
				[timelineViewItem setIsRead:YES];
				[timelineViewItem updateClassNames];
			}
		}
		
		[timelineUnreadItemsDict removeObjectForKey:key];
		
		// classic views
		for (CLWindowController *windowController in windowControllers) {
			for (CLTabViewItem *tabViewItem in [[windowController tabView] tabViewItems]) {
				
				if ([tabViewItem tabType] == CLClassicType) {
					CLClassicView *classicView = [tabViewItem classicView];
					CLPost *post = [[classicView unreadItemsDict] objectForKey:key];
					
					if (post != nil) {
						[post setIsRead:YES];
						
						[[classicView unreadItemsDict] removeObjectForKey:key];
					}
					
					[[classicView tableView] setNeedsDisplay:YES];
				}
			}
		}
	}
}

- (NSString *)OPMLString {
	NSMutableString *returnString = [NSMutableString string];
	
	[returnString appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"];
	[returnString appendString:@"<opml version=\"1.0\">\r\n"];
	[returnString appendString:@"\t<head>\r\n"];
	[returnString appendString:@"\t\t<title>Syndication Subscriptions</title>\r\n"];
	[returnString appendString:@"\t</head>\r\n"];
	[returnString appendString:@"\t<body>\r\n"];
	
	for (CLSourceListItem *item in subscriptionList) {
		[returnString appendString:[self OPMLStringForItem:item indentLevel:2]];
	}
	
	[returnString appendString:@"\t</body>\r\n"];
	[returnString appendString:@"</opml>\r\n"];
	
	return returnString;
}

- (NSString *)OPMLStringForItem:(CLSourceListItem *)item indentLevel:(NSUInteger)indentLevel {
	NSMutableString *returnString = [NSMutableString string];
	
	if ([item isKindOfClass:[CLSourceListFolder class]]) {
		CLSourceListFolder *folder = (CLSourceListFolder *)item;
		
		NSString *title = [folder title];
		
		if (title == nil) {
			title = @"";
		}
		
		title = [title clEscapeXMLString];
		
		for (NSUInteger i=0; i<indentLevel; i++) {
			[returnString appendString:@"\t"];
		}
		
		[returnString appendFormat:@"<outline text=\"%@\">\r\n", title];
		
		for (CLSourceListItem *child in [folder children]) {
			[returnString appendString:[self OPMLStringForItem:child indentLevel:(indentLevel + 1)]];
		}
		
		for (NSUInteger i=0; i<indentLevel; i++) {
			[returnString appendString:@"\t"];
		}
		
		[returnString appendString:@"</outline>\r\n"];
		
	} else if ([item isKindOfClass:[CLSourceListFeed class]]) {
		CLSourceListFeed *feed = (CLSourceListFeed *)item;
		
		NSString *title = [feed title];
		NSString *xmlUrl = [feed url];
		NSString *htmlUrl = [feed websiteLink];
		
		if (title == nil) {
			title = @"";
		}
		
		if (xmlUrl == nil) {
			xmlUrl = @"";
		}
		
		if (htmlUrl == nil) {
			htmlUrl = @"";
		}
		
		title = [title clEscapeXMLString];
		xmlUrl = [xmlUrl clEscapeXMLString];
		htmlUrl = [htmlUrl clEscapeXMLString];
		
		if ([xmlUrl isEqual:@""] == NO) {
			for (NSUInteger i=0; i<indentLevel; i++) {
				[returnString appendString:@"\t"];
			}
			
			[returnString appendFormat:@"<outline text=\"%@\" type=\"rss\" xmlUrl=\"%@\" htmlUrl=\"%@\" />\r\n", title, xmlUrl, htmlUrl];
		}
	}
	
	return returnString;
}

- (void)processOPML:(CLXMLNode *)rootNode {
	NSMutableArray *stack = [NSMutableArray array];
	NSMutableArray *newFeedsAndFolders = [NSMutableArray array];
	NSMutableArray *folderIdStack = [NSMutableArray array];
	NSMutableDictionary *folderLookup = [NSMutableDictionary dictionary];
	
	[stack addObject:rootNode];
	[folderIdStack addObject:[NSNumber numberWithInteger:0]];
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	while ([stack count] > 0) {
		CLXMLNode *node = [stack lastObject];
		[stack removeLastObject];
		
		CLSourceListFolder *justAddedFolder = nil;
		CLSourceListFolder *parentFolder = nil;
		NSNumber *parentId = [folderIdStack lastObject];
		[folderIdStack removeLastObject];
		
		if ([parentId isEqualToNumber:[NSNumber numberWithInteger:0]]) {
			parentId = nil;
		}
		
		if (parentId != nil) {
			parentFolder = [folderLookup objectForKey:parentId];
		}
		
		NSString *nodeName = [[node name] lowercaseString];
		NSDictionary *nodeAttributes = [node attributes];
		
		if ([nodeName isEqual:@"outline"]) {
			NSString *nodeType = [[nodeAttributes valueForKey:@"type"] clUnescapeXMLString];
			NSString *nodeTitle = [[nodeAttributes valueForKey:@"text"] clUnescapeXMLString];
			
			if (nodeTitle == nil) {
				nodeTitle = [[nodeAttributes valueForKey:@"title"] clUnescapeXMLString];
			}
			
			if (nodeType == nil || [nodeType isEqual:@"rss"] == NO) {
				
				[db executeUpdate:@"INSERT INTO folder (ParentId, Title) VALUES (?, ?)", parentId, nodeTitle];
				
				NSInteger insertId = [db lastInsertRowId];
				NSMutableString *folderPath = [NSMutableString string];
				
				if (parentFolder != nil) {
					[folderPath appendString:[parentFolder path]];
				}
				
				[folderPath appendFormat:@"%ld/", insertId];
				
				[db executeUpdate:@"UPDATE folder SET Path=? WHERE Id=?", folderPath, [NSNumber numberWithInteger:insertId]];
				
				CLSourceListFolder *folder = [[[CLSourceListFolder alloc] init] autorelease];
				[folder setTitle:nodeTitle];
				[folder setDbId:insertId];
				[folder setPath:folderPath];
				
				[folderLookup setObject:folder forKey:[NSNumber numberWithInteger:[folder dbId]]];
				
				if (parentFolder != nil) {
					[folder setParentFolderReference:parentFolder];
				}
				
				[newFeedsAndFolders addObject:folder];
				justAddedFolder = folder;
				
			} else {
				
				NSString *nodeXmlUrl = [[nodeAttributes valueForKey:@"xmlUrl"] clUnescapeXMLString];
				
				if (nodeXmlUrl != nil) {
					BOOL feedAlreadyInDB = NO;
					
					FMResultSet *rs = [db executeQuery:@"SELECT * FROM feed WHERE Url=? AND IsHidden=0", nodeXmlUrl];
					
					if ([rs next]) {
						feedAlreadyInDB = YES;
					}
					
					[rs close];
					
					// if the title is just the url, we will leave the title blank and find the real title
					if (nodeTitle != nil && [nodeTitle isEqual:nodeXmlUrl]) {
						nodeTitle = nil;
					}
					
					if (feedAlreadyInDB == NO) {
						[db executeUpdate:@"INSERT INTO feed (FolderId, Url, Title) VALUES (?, ?, ?)", parentId, nodeXmlUrl, nodeTitle];
						NSInteger rowId = [db lastInsertRowId];
						
						CLSourceListFeed *feed = [[[CLSourceListFeed alloc] init] autorelease];
						[feed setTitle:nodeTitle];
						[feed setDbId:rowId];
						[feed setUrl:nodeXmlUrl];
						
						[feedLookupDict setObject:feed forKey:[NSNumber numberWithInteger:[feed dbId]]];
						
						if (parentFolder != nil) {
							[feed setEnclosingFolderReference:parentFolder];
						}
						
						[newFeedsAndFolders addObject:feed];
					}
				}
			}
		}
		
		for (CLXMLNode *child in [node children]) {
			[stack addObject:child];
			
			if (justAddedFolder != nil) {
				[folderIdStack addObject:[NSNumber numberWithInteger:[justAddedFolder dbId]]];
			} else {
				[folderIdStack addObject:[NSNumber numberWithInteger:0]];
			}
		}
	}
	
	[db close];
	
	NSMutableArray *feeds = [NSMutableArray array];
	
	for (CLSourceListItem *item in newFeedsAndFolders) {
		if ([item isKindOfClass:[CLSourceListFeed class]]) {
			CLSourceListFeed *feed = (CLSourceListFeed *)item;
			
			if ([feed enclosingFolderReference] != nil) {
				[[[feed enclosingFolderReference] children] addObject:feed];
			} else {
				[subscriptionList addObject:feed];
			}
			
			[feeds addObject:feed];
			
		} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
			CLSourceListFolder *folder = (CLSourceListFolder *)item;
			
			if ([folder parentFolderReference] != nil) {
				[[[folder parentFolderReference] children] addObject:folder];
			} else {
				[subscriptionList addObject:folder];
			}
		}
	}
	
	if ([feeds count] > 0) {
		[self queueSyncRequestForSpecificFeeds:feeds];
	}
	
	[self sortSourceList];
	[self sourceListDidChange];
	[self restoreSourceListSelections];
}

- (void)numberOfTabsDidChange {
	[self updateMenuItems];
}

- (void)tabSelectionDidChange {
	[self updateMenuItems];
}

- (void)timelineSelectionDidChange {
	[self updateMenuItems];
}

- (void)classicViewSelectionDidChange {
	[self updateMenuItems];
}

- (void)webTabDidFinishLoad {
	[self updateMenuItems];
}

- (void)sourceListDidChange {
	for (CLWindowController *windowController in windowControllers) {
		[windowController refreshSourceList];
	}
	
	[self updateSubscriptionsMenu];
}

- (void)sourceListDidRenameItem:(CLSourceListItem *)item {
	
	[self sortSourceList];
	[self sourceListDidChange];
	[self restoreSourceListSelections];
	[self refreshAllActivityViews];
	
	for (CLWindowController *windowController in windowControllers) {
		
		// update the label for any open tabs
		for (CLTabViewItem *tabViewItem in [[windowController tabView] tabViewItems]) {
			if ([tabViewItem sourceListItem] == item) {
				[tabViewItem setLabel:[item extractTitleForDisplay]];
				[[windowController tabView] setNeedsDisplay:YES];
			}
			
			// refresh classic views (so feed titles can update there too)
			if ([tabViewItem tabType] == CLClassicType) {
				CLClassicView *classicView = [tabViewItem classicView];
				[[classicView tableView] setNeedsDisplay:YES];
			}
		}
		
		[windowController updateWindowTitle];
	}
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		CLSourceListFeed *feed = (CLSourceListFeed *)item;
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET Title=? WHERE Id=?", [feed title], [NSNumber numberWithInteger:[feed dbId]], nil];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		CLSourceListFolder *folder = (CLSourceListFolder *)item;
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE folder SET Title=? WHERE Id=?", [folder title], [NSNumber numberWithInteger:[folder dbId]], nil];
	}
}

- (void)openNewWindowForSubscription:(CLSourceListItem *)subscription {
	NSWindow *newWin = [[self newWindow] window];
	
	if (newWin != nil) {
		CLWindowController *windowController = [newWin windowController];
		
		if ([windowController selectSourceListItem:subscription] == NO) {
			[windowController selectSourceListItem:nil];
			[windowController openItemInCurrentTab:subscription orQuery:nil];
		}
	}
}

- (void)openNewWindowForUrlRequest:(NSURLRequest *)request {
	NSWindow *newWin = [[self newWindow] window];
	
	if (newWin != nil) {
		CLWindowController *windowController = [newWin windowController];
		[windowController selectSourceListItem:nil];
		[windowController openNewWebTabWith:request selectTab:NO];
		[windowController closeTab]; // this closes the empty tab that is automatically opened when we create a new window
	}
}

- (void)changeNewItemsBadgeValueBy:(NSInteger)value {
	
	if (value == 0) {
		return;
	}
	
	for (CLWindowController *windowController in windowControllers) {
		CLSourceListItem *newItems = [windowController sourceListNewItems];
		[newItems setBadgeValue:([newItems badgeValue] + value)];
		
		if ([newItems badgeValue] < 0) {
			[newItems setBadgeValue:0];
		}
	}
	
	[self setTotalUnread:(totalUnread + value)];
	
	if (totalUnread < 0) {
		[self setTotalUnread:0];
	}
	
	[self updateDockTile];
}

- (void)clearNewItemsBadgeValue {
	
	for (CLWindowController *windowController in windowControllers) {
		CLSourceListItem *newItems = [windowController sourceListNewItems];
		[newItems setBadgeValue:0];
	}
	
	[self setTotalUnread:0];
	
	[self updateDockTile];
}

- (void)updateDockTile {
	if (totalUnread > 0 && preferenceDisplayUnreadCountInDock) {
		[[[NSApplication sharedApplication] dockTile] setBadgeLabel:[NSString stringWithFormat:@"%lu", totalUnread]];
	} else {
		[[[NSApplication sharedApplication] dockTile] setBadgeLabel:nil];
	}
}

- (void)refreshTabsForAncestorsOf:(CLSourceListItem *)item {
	for (CLWindowController *windowController in windowControllers) {
		[windowController refreshTabsForAncestorsOf:item];
	}
}

- (void)refreshTabsFor:(CLSourceListItem *)item {
	for (CLWindowController *windowController in windowControllers) {
		[windowController refreshTabsFor:item];
	}
}

- (void)refreshTabsForNewItems {
	for (CLWindowController *windowController in windowControllers) {
		[windowController refreshTabsFor:[windowController sourceListNewItems]];
	}
}

- (void)refreshTabsForStarredItems {
	for (CLWindowController *windowController in windowControllers) {
		[windowController refreshTabsFor:[windowController sourceListStarredItems]];
	}
}

- (void)refreshSearchTabs {
	for (CLWindowController *windowController in windowControllers) {
		[windowController refreshSearchTabs];
	}
}

- (void)refreshAllActivityViews {
	for (CLWindowController *windowController in windowControllers) {
		[[windowController activityView] setNeedsDisplay:YES];
	}
}

- (void)restoreSourceListSelections {
	for (CLWindowController *windowController in windowControllers) {
		if ([windowController selectSourceListItem:[windowController sourceListSelectedItem]] == NO) {
			[windowController selectSourceListItem:nil];
		}
	}
}

- (CLSourceListFeed *)feedForDbId:(NSInteger)dbId {
	CLSourceListFeed *feed = nil;
	
	if (dbId <= 0) {
		return nil;
	}
	
	feed = [feedLookupDict objectForKey:[NSNumber numberWithInteger:dbId]];
	
	if (feed != nil) {
		[[feed retain] autorelease];
	}
	
	return feed;
}

- (CLPost *)postForDbId:(NSInteger)dbId {
	CLPost *post = nil;
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	FMResultSet *rs = [db executeQuery:@"SELECT post.*, feed.Title AS FeedTitle, feed.Url AS FeedUrlString FROM post, feed WHERE post.FeedId=feed.Id AND post.Id=?", [NSNumber numberWithInteger:dbId]];
	
	if ([rs next]) {
		post = [[[CLPost alloc] initWithResultSet:rs] autorelease];
		
		if ([rs boolForColumn:@"HasEnclosures"]) {
			FMResultSet *rs2 = [db executeQuery:@"SELECT * FROM enclosure WHERE PostId=?", [NSNumber numberWithInteger:dbId]];
			
			while ([rs2 next]) {
				[[post enclosures] addObject:[rs2 stringForColumn:@"Url"]];
			}
			
			[rs2 close];
		}
	}
	
	[rs close];
	[db close];
	
	return post;
}

- (CLSourceListFeed *)addSubscriptionForUrlString:(NSString *)url withTitle:(NSString *)feedTitle toFolder:(CLSourceListFolder *)folder refreshImmediately:(BOOL)shouldRefresh {
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	NSNumber *folderId = nil;
	NSInteger rowId = 0;
	
	if (folder != nil) {
		folderId = [NSNumber numberWithInteger:[folder dbId]];
	}
	
	BOOL hasHiddenEquivalent = NO;
	
	[db executeUpdate:@"INSERT INTO feed (FolderId, Url, Title) VALUES (?, ?, ?)", folderId, url, feedTitle];
	
	rowId = [db lastInsertRowId];
	
	[db close];
	
	CLSourceListFeed *newSub = nil;
	
	if (hasHiddenEquivalent) {
		newSub = [self feedForDbId:rowId];
	} else {
		newSub = [[[CLSourceListFeed alloc] init] autorelease];
	}
	
	[newSub setTitle:feedTitle];
	[newSub setDbId:rowId];
	[newSub setUrl:url];
	
	if (hasHiddenEquivalent == NO) {
		[feedLookupDict setObject:newSub forKey:[NSNumber numberWithInteger:[newSub dbId]]];
	}
	
	if (folder != nil) {
		[newSub setEnclosingFolderReference:folder];
		[[folder children] addObject:newSub];
	} else {
		[subscriptionList addObject:newSub];
	}
	
	[self sortSourceList];
	[self sourceListDidChange];
	[self restoreSourceListSelections];
	
	if (shouldRefresh) {
		[self queueSyncRequestForSpecificFeeds:[NSMutableArray arrayWithObject:newSub]];
	}
	
	return newSub;
}

- (CLSourceListFolder *)addFolderWithTitle:(NSString *)folderTitle toFolder:(CLSourceListFolder *)parentFolder forWindow:(CLWindowController *)winController {
	
	if (folderTitle == nil) {
		folderTitle = @"(Untitled)";
	}
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	NSNumber *parentId = nil;
	
	if (parentFolder != nil) {
		parentId = [NSNumber numberWithInteger:[parentFolder dbId]];
	}
	
	[db executeUpdate:@"INSERT INTO folder (ParentId, Title) VALUES (?, ?)", parentId, folderTitle];
	
	NSInteger insertId = [db lastInsertRowId];
	NSMutableString *folderPath = [NSMutableString string];
	
	if (parentFolder != nil) {
		[folderPath appendString:[parentFolder path]];
	}
	
	[folderPath appendFormat:@"%ld/", insertId];
	
	[db executeUpdate:@"UPDATE folder SET Path=? WHERE Id=?", folderPath, [NSNumber numberWithInteger:insertId]];
	
	[db close];
	
	CLSourceListFolder *folder = [[[CLSourceListFolder alloc] init] autorelease];
	[folder setTitle:folderTitle];
	[folder setDbId:insertId];
	[folder setPath:folderPath];
	
	if (parentFolder != nil) {
		[folder setParentFolderReference:parentFolder];
		[[parentFolder children] addObject:folder];
	} else {
		[subscriptionList addObject:folder];
	}
	
	[self sortSourceList];
	[self sourceListDidChange];
	[self restoreSourceListSelections];
	
	if (winController != nil) {
		[winController editSourceListItem:folder];
	}
	
	return folder;
}

- (void)sortSourceList {
	[self sortSourceListHelper:subscriptionList];
}

- (void)sortSourceListHelper:(NSMutableArray *)children {
	[children sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	
	// look for folders and sort them too
	for (CLSourceListItem *item in children) {
		if ([item isKindOfClass:[CLSourceListFolder class]]) {
			[self sortSourceListHelper:[item children]];
		}
	}
}

- (void)deleteSourceListItem:(CLSourceListItem *)item {
	
	if (item == nil) {
		return;
	}
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	[db beginTransaction];
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		CLSourceListFeed *feed = (CLSourceListFeed *)item;
		[db executeUpdate:@"DELETE FROM enclosure WHERE PostId IN (SELECT Id FROM post WHERE FeedId=?)", [NSNumber numberWithInteger:[feed dbId]]];
		[db executeUpdate:@"DELETE FROM post WHERE FeedId=?", [NSNumber numberWithInteger:[feed dbId]]];
		[db executeUpdate:@"DELETE FROM feed WHERE Id=?", [NSNumber numberWithInteger:[feed dbId]]];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		CLSourceListFolder *folder = (CLSourceListFolder *)item;
		[db executeUpdate:[NSString stringWithFormat:@"DELETE FROM enclosure WHERE PostId IN (SELECT post.Id FROM post, feed, folder WHERE post.FeedId=feed.Id AND feed.FolderId=folder.Id AND folder.Path LIKE '%@%%')", [folder path]]];
		[db executeUpdate:[NSString stringWithFormat:@"DELETE FROM post WHERE Id IN (SELECT post.Id FROM post, feed, folder WHERE post.FeedId=feed.Id AND feed.FolderId=folder.Id AND folder.Path LIKE '%@%%')", [folder path]]];
		[db executeUpdate:[NSString stringWithFormat:@"DELETE FROM feed WHERE Id IN (SELECT feed.Id FROM feed, folder WHERE feed.FolderId=folder.Id AND folder.Path LIKE '%@%%')", [folder path]]];
		[db executeUpdate:[NSString stringWithFormat:@"DELETE FROM folder WHERE Path LIKE '%@%%'", [folder path]]];
	}
	
	[db commit];
	
	[db close];
	
	// for each window, if the selected tab is for the item we are deleting (or a descendent), change it to be for new items
	for (CLWindowController *windowController in windowControllers) {
		CLTabViewItem *selectedTabViewItem = [[windowController tabView] selectedTabViewItem];
		
		if (([selectedTabViewItem tabType] == CLTimelineType || [selectedTabViewItem tabType] == CLClassicType) && 
			([selectedTabViewItem sourceListItem] == item || [SyndicationAppDelegate isSourceListItem:[selectedTabViewItem sourceListItem] descendentOf:item])) {
			
			// this check seems like it will always pass, but it won't
			// it will fail if the item being displayed in the selected tab isn't selected in the source list
			// this happens often with multiple tabs open
			if ([windowController sourceListSelectedItem] == item || [SyndicationAppDelegate isSourceListItem:[windowController sourceListSelectedItem] descendentOf:item]) {
				[windowController selectSourceListItem:[windowController sourceListNewItems]];
			}
			
			[windowController openItemInCurrentTab:[windowController sourceListNewItems] orQuery:nil];
			[[windowController tabView] setNeedsDisplay:YES];
			
			if ([selectedTabViewItem tabType] == CLTimelineType) {
				[[selectedTabViewItem timelineView] setNeedsDisplay:YES];
			}
		}
	}
	
	if ([item badgeValue] > 0) {
		[SyndicationAppDelegate changeBadgeValuesBy:([item badgeValue] * -1) forAncestorsOfItem:item];
		[self changeNewItemsBadgeValueBy:([item badgeValue] * -1)];
	}
	
	[self closeAllTabsForSourceListItem:item];
	[self cancelAllActivityFor:item];
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		[self didDeleteFeed:(CLSourceListFeed *)item];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		[self didDeleteFolder:(CLSourceListFolder *)item];
	}
	
	BOOL didDeleteEmptyFolder = NO;
	
	if ([item isKindOfClass:[CLSourceListFolder class]] && [[item children] count] == 0) {
		didDeleteEmptyFolder = YES;
	}
	
	if (didDeleteEmptyFolder == NO) {
		[self refreshTabsForNewItems];
		[self refreshTabsForStarredItems];
		[self refreshSearchTabs];
		[self refreshTabsForAncestorsOf:item];
	}
	
	CLSourceListFolder *ancestor = nil;
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		ancestor = [(CLSourceListFeed *)item enclosingFolderReference];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		ancestor = [(CLSourceListFolder *)item parentFolderReference];
	}
	
	if (ancestor != nil) {
		[[ancestor children] removeObject:item];
		
		if ([item isKindOfClass:[CLSourceListFeed class]]) {
			[(CLSourceListFeed *)item setEnclosingFolderReference:nil];
		} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
			[(CLSourceListFolder *)item setParentFolderReference:nil];
		}
	} else {
		[subscriptionList removeObject:item];
	}
	
	[self sourceListDidChange];
	[self restoreSourceListSelections];
}

- (void)didDeleteFeed:(CLSourceListFeed *)feed {
	if (feed != nil && [feed dbId] > 0) {
		[feedLookupDict removeObjectForKey:[NSNumber numberWithInteger:[feed dbId]]];
		[feedsToSync removeObject:feed];
		
		for (CLFeedRequest *feedRequest in feedRequests) {
			if ([feedRequest feed] == feed) {
				[feedRequest stopConnection];
			}
		}
	}
}

- (void)didDeleteFolder:(CLSourceListFolder *)folder {
	if (folder != nil) {
		for (CLSourceListItem *child in [folder children]) {
			if ([child isKindOfClass:[CLSourceListFeed class]]) {
				[self didDeleteFeed:(CLSourceListFeed *)child];
			} else if ([child isKindOfClass:[CLSourceListFeed class]]) {
				[self didDeleteFolder:(CLSourceListFolder *)child];
			}
		}
	}
}

- (void)markAllAsReadForSourceListItem:(CLSourceListItem *)item orNewItems:(BOOL)newItems orStarredItems:(BOOL)starredItems orPostsOlderThan:(NSNumber *)timestamp {
	
	if (item == nil && newItems == NO && starredItems == NO && timestamp == nil) {
		return;
	}
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	NSMutableArray *posts = [NSMutableArray array];
	FMResultSet *rs = nil;
	
	if (newItems) {
		rs = [db executeQuery:@"SELECT post.Id, post.Guid, post.FeedId, FROM post, feed WHERE post.FeedId=feed.Id AND post.IsRead=0"];
	} else if (starredItems) {
		rs = [db executeQuery:@"SELECT post.Id, post.Guid, post.FeedId, FROM post, feed WHERE post.FeedId=feed.Id AND post.IsRead=0 AND post.IsStarred=1"];
	} else if (item != nil && [item isKindOfClass:[CLSourceListFeed class]]) {
		rs = [db executeQuery:@"SELECT post.Id, post.Guid, post.FeedId, FROM post, feed WHERE post.FeedId=feed.Id AND post.FeedId=? AND post.IsRead=0", [NSNumber numberWithInteger:[(CLSourceListFeed *)item dbId]]];
	} else if (item != nil && [item isKindOfClass:[CLSourceListFolder class]]) {
		rs = [db executeQuery:[NSString stringWithFormat:@"SELECT post.Id, post.Guid, post.FeedId, FROM post, feed WHERE post.Id IN (SELECT post.Id FROM post, feed, folder WHERE post.FeedId=feed.Id AND feed.FolderId=folder.Id AND folder.Path LIKE '%@%%') AND post.FeedId=feed.Id AND post.IsRead=0", [(CLSourceListFolder *)item path]]];
	} else if (timestamp != nil) {
		rs = [db executeQuery:@"SELECT post.Id, post.Guid, post.FeedId, FROM post, feed WHERE post.FeedId=feed.Id AND post.IsRead=0 AND post.Received < ?", timestamp];
	}
	
	while ([rs next]) {
		NSMutableDictionary *post = [NSMutableDictionary dictionary];
		[post setValue:[NSNumber numberWithInteger:[rs longForColumn:@"Id"]] forKey:@"Id"];
		[post setValue:[rs stringForColumn:@"Guid"] forKey:@"Guid"];
		[post setValue:[NSNumber numberWithInteger:[rs longForColumn:@"FeedId"]] forKey:@"FeedId"];
		[posts addObject:post];
	}
	
	[rs close];
	[db close];
	
	for (NSDictionary *post in posts) {
		[self markViewItemsAsReadForPostDbId:[[post objectForKey:@"Id"] integerValue]];
	}
	
	BOOL doManualUpdate = NO;
	
	if (newItems) {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsRead=1", nil];
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET UnreadCount=0", nil];
	} else if (starredItems) {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsRead=1 WHERE IsStarred=1", nil];
		doManualUpdate = YES;
	} else if (item != nil && [item isKindOfClass:[CLSourceListFeed class]]) {
		NSNumber *dbIdNum = [NSNumber numberWithInteger:[(CLSourceListFeed *)item dbId]];
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsRead=1 WHERE FeedId=? AND IsRead=0", dbIdNum, nil];
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET UnreadCount=0 WHERE Id=?", dbIdNum, nil];
	} else if (item != nil && [item isKindOfClass:[CLSourceListFolder class]]) {
		[self runDatabaseUpdateOnBackgroundThread:[NSString stringWithFormat:@"UPDATE post SET IsRead=1 WHERE Id IN (SELECT post.Id FROM post, feed, folder WHERE post.FeedId=feed.Id AND feed.FolderId=folder.Id AND folder.Path LIKE '%@%%') AND IsRead=0", [(CLSourceListFolder *)item path]], nil];
		doManualUpdate = YES;
	} else if (timestamp != nil) {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsRead=1 WHERE IsRead=0 AND Received < ?", timestamp, nil];
		doManualUpdate = YES;
	}
	
	if (doManualUpdate) {
		NSMutableSet *feedsToUpdateUnreadCount = [NSMutableSet set];
		
		for (NSDictionary *post in posts) {
			NSNumber *feedId = [post objectForKey:@"FeedId"];
			
			if (feedId != nil && [feedId integerValue] > 0) {
				CLSourceListFeed *feed = [self feedForDbId:[feedId integerValue]];
				
				if (feed != nil) {
					[feedsToUpdateUnreadCount addObject:feed];
				}
			}
		}
		
		for (CLSourceListFeed *feed in feedsToUpdateUnreadCount) {
			NSNumber *feedId = [NSNumber numberWithInteger:[feed dbId]];
			[self runDatabaseUpdateOnBackgroundThread:UNREAD_COUNT_QUERY, feedId, feedId, nil];
		}
	}
	
	if (newItems) {
		[self clearNewItemsBadgeValue];
		
		for (CLSourceListItem *subscription in subscriptionList) {
			[SyndicationAppDelegate clearBadgeValuesForItemAndDescendents:subscription];
		}
	} else if (item != nil) {
		[SyndicationAppDelegate changeBadgeValuesBy:([item badgeValue] * -1) forAncestorsOfItem:item];
		[self changeNewItemsBadgeValueBy:([item badgeValue] * -1)];
		[SyndicationAppDelegate clearBadgeValuesForItemAndDescendents:item];
	} else {
		for (NSDictionary *post in posts) {
			CLSourceListFeed *feed = [self feedForDbId:[[post objectForKey:@"FeedId"] integerValue]];
			
			if (feed != nil) {
				[SyndicationAppDelegate changeBadgeValueBy:-1 forItem:feed];
				[SyndicationAppDelegate changeBadgeValuesBy:-1 forAncestorsOfItem:feed];
			}
			
			[self changeNewItemsBadgeValueBy:-1];
		}
	}
	
	[self sourceListDidChange];
}

- (void)refreshSourceListItem:(CLSourceListItem *)item {
	
	if (item == nil) {
		return;
	}
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		[self refreshSourceListFeed:(CLSourceListFeed *)item];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		[self refreshSourceListFolder:(CLSourceListFolder *)item];
	}
}

- (void)refreshSourceListFeed:(CLSourceListFeed *)feed {
	[self queueSyncRequestForSpecificFeeds:[NSMutableArray arrayWithObject:feed]];
}

- (void)refreshSourceListFolder:(CLSourceListFolder *)folder {
	for (CLSourceListItem *child in [folder children]) {
		[self refreshSourceListItem:child];
	}
}

- (void)removeOldArticles {
	
	if (preferenceRemoveArticles > 0) {
		NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
		NSInteger olderThan = timestamp - preferenceRemoveArticles;
		
		// first mark them as read
		[self markAllAsReadForSourceListItem:nil orNewItems:NO orStarredItems:NO orPostsOlderThan:[NSNumber numberWithInteger:olderThan]];
		
		// then hide them
		NSMutableArray *oldArticleDbIds = [NSMutableArray array];
		
		FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
		
		if (![db open]) {
			[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
		}
		
		FMResultSet *rs = [db executeQuery:@"SELECT Id FROM post WHERE IsHidden=0 AND Received < ? AND IsStarred=0", [NSNumber numberWithInteger:olderThan]];
		
		while ([rs next]) {
			[oldArticleDbIds addObject:[NSNumber numberWithInteger:[rs longForColumn:@"Id"]]];
		}
		
		[rs close];
		[db close];
		
		for (NSNumber *dbId in oldArticleDbIds) {
			for (CLWindowController *windowController in windowControllers) {
				for (CLTabViewItem *tabViewItem in [[windowController tabView] tabViewItems]) {
					
					if ([tabViewItem tabType] == CLClassicType) {
						CLClassicView *classicView = [tabViewItem classicView];
						NSInteger indexOfItemToRemove = -1;
						NSInteger i = 0;
						
						for (CLPost *post in [classicView posts]) {
							if ([post dbId] == [dbId integerValue]) {
								indexOfItemToRemove = i;
								break;
							}
							i++;
						}
						
						if (indexOfItemToRemove >= 0) {
							[classicView removePostsInRange:NSMakeRange(indexOfItemToRemove, 1) preserveScrollPosition:YES updateMetadata:NO ignoreSelection:NO];
							[[classicView tableView] setNeedsDisplay:YES];
						}
						
					} else if ([tabViewItem tabType] == CLTimelineType) {
						CLTimelineView *timelineView = [tabViewItem timelineView];
						NSInteger indexOfItemToRemove = -1;
						NSInteger i = 0;
						
						for (CLTimelineViewItem *timelineViewItem in [timelineView timelineViewItems]) {
							if ([timelineViewItem postDbId] == [dbId integerValue]) {
								indexOfItemToRemove = i;
								break;
							}
							i++;
						}
						
						if (indexOfItemToRemove >= 0) {
							[timelineView removePostsInRange:NSMakeRange(indexOfItemToRemove, 1) preserveScrollPosition:YES updateMetadata:NO];
							[timelineView updateSubviewRects];
							[timelineView setNeedsDisplay:YES];
							
							[windowController selectItemAtTopOfTimelineView:timelineView];
						}
					}
					
					[windowController updateViewVisibilityForTab:tabViewItem];
				}
			}
		}
		
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsHidden=1 WHERE Received < ? AND IsStarred=0", [NSNumber numberWithInteger:olderThan], nil];
	}
}

- (void)markArticlesAsRead {
	
	if (preferenceMarkArticlesAsRead > 0) {
		NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
		NSInteger olderThan = timestamp - preferenceMarkArticlesAsRead;
		
		[self markAllAsReadForSourceListItem:nil orNewItems:NO orStarredItems:NO orPostsOlderThan:[NSNumber numberWithInteger:olderThan]];
	}
}

- (void)moveItem:(CLSourceListItem *)item toFolder:(CLSourceListFolder *)folder {
	
	NSString *previousFolder = nil;
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		if ([(CLSourceListFeed *)item enclosingFolderReference] != nil) {
			previousFolder = [[(CLSourceListFeed *)item enclosingFolderReference] title];
		}
	}
	
	NSNumber *folderId = nil;
	
	if (folder != nil) {
		folderId = [NSNumber numberWithInteger:[folder dbId]];
	}
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE feed SET FolderId=? WHERE Id=?", folderId, [NSNumber numberWithInteger:[(CLSourceListFeed *)item dbId]], nil];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE folder SET ParentId=? WHERE Id=?", folderId, [NSNumber numberWithInteger:[(CLSourceListFolder *)item dbId]], nil];
		
		// update the path for this item and any descendents
		NSString *oldPath = [(CLSourceListFolder *)item path];
		NSMutableString *newPath = [NSMutableString string];
		
		if (folder != nil) {
			[newPath appendString:[folder path]];
		}
		
		[newPath appendFormat:@"%ld/", [(CLSourceListFolder *)item dbId]];
		
		NSString *query = [NSString stringWithFormat:@"UPDATE folder SET Path=REPLACE(Path, '%@', '%@') WHERE Path LIKE '%@%%'", oldPath, newPath, oldPath];
		
		[self runDatabaseUpdateOnBackgroundThread:query, nil];
		
		[(CLSourceListFolder *)item setPath:newPath];
	}
	
	// update ui
	CLSourceListFolder *ancestor = nil;
	
	[self refreshTabsForAncestorsOf:item];
	
	if ([item isKindOfClass:[CLSourceListFeed class]]) {
		ancestor = [(CLSourceListFeed *)item enclosingFolderReference];
	} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
		ancestor = [(CLSourceListFolder *)item parentFolderReference];
	}
	
	// remove it from its previous location
	if (ancestor != nil) {
		[SyndicationAppDelegate changeBadgeValuesBy:([item badgeValue] * -1) forAncestorsOfItem:item];
		[[ancestor children] removeObject:item];
		
		if ([item isKindOfClass:[CLSourceListFeed class]]) {
			[(CLSourceListFeed *)item setEnclosingFolderReference:nil];
		} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
			[(CLSourceListFolder *)item setParentFolderReference:nil];
		}
	} else {
		[subscriptionList removeObject:item];
	}
	
	if (folder != nil) {
		
		[[folder children] addObject:item];
		
		if ([item isKindOfClass:[CLSourceListFeed class]]) {
			[(CLSourceListFeed *)item setEnclosingFolderReference:folder];
		} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
			[(CLSourceListFolder *)item setParentFolderReference:folder];
		}
		
		[SyndicationAppDelegate changeBadgeValuesBy:[item badgeValue] forAncestorsOfItem:item];
		
	} else {
		[subscriptionList addObject:item];
	}
	
	[self sortSourceList];
	[self sourceListDidChange];
	[self refreshTabsForAncestorsOf:item];
	[self restoreSourceListSelections];
}

- (void)addStarToPost:(CLPost *)post {
	[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsStarred=1 WHERE Id=?", [NSNumber numberWithInteger:[post dbId]], nil];
	
	[post setIsStarred:YES];
	
	[self addPostsToAllWindows:[NSArray arrayWithObject:post] forFeed:nil orNewItems:NO orStarredItems:YES];
}

- (void)removeStarFromPost:(CLPost *)post {
	
	if ([post dbId] <= 0 || [post feedDbId] <= 0) {
		return;
	}
	
	[post retain];
	
	BOOL isForHiddenFeed = NO;
	
	FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
	
	if (![db open]) {
		[NSException raise:@"Database error" format:@"Failed to connect to the database!"];
	}
	
	FMResultSet *rs = [db executeQuery:@"SELECT * FROM feed WHERE Id=?", [NSNumber numberWithInteger:[post feedDbId]]];
	
	if ([rs next]) {
		isForHiddenFeed = [rs boolForColumn:@"IsHidden"];
	}
	
	[rs close];
	
	if (isForHiddenFeed) {
		[db beginTransaction];
		
		[db executeUpdate:@"DELETE FROM enclosure WHERE PostId=?", [NSNumber numberWithInteger:[post dbId]]];
		[db executeUpdate:@"DELETE FROM post WHERE Id=?", [NSNumber numberWithInteger:[post dbId]]];
		
		BOOL hiddenFeedHasMorePosts = NO;
		
		rs = [db executeQuery:@"SELECT * FROM post WHERE FeedId=? LIMIT 1", [NSNumber numberWithInteger:[post feedDbId]]];
		
		if ([rs next]) {
			hiddenFeedHasMorePosts = YES;
		}
		
		[rs close];
		
		if (hiddenFeedHasMorePosts == NO) {
			[db executeUpdate:@"DELETE FROM feed WHERE Id=?", [NSNumber numberWithInteger:[post feedDbId]]];
			[feedLookupDict removeObjectForKey:[NSNumber numberWithInteger:[post feedDbId]]];
		}
		
		[db commit];
		
	} else {
		[self runDatabaseUpdateOnBackgroundThread:@"UPDATE post SET IsStarred=0 WHERE Id=?", [NSNumber numberWithInteger:[post dbId]], nil];
	}
	
	[db close];
	
	[post setIsStarred:NO];
	
	[self removeStarredPostFromAllWindows:post];
	
	[post release];
}


#pragma mark IBActions

- (IBAction)showPreferencesWindow:(id)sender {
	if (preferencesWindow == nil) {
		[NSBundle loadNibNamed:@"CLPreferencesWindow" owner:self];
		[preferencesWindow setExcludedFromWindowsMenu:YES];
		[preferencesWindow setDelegate:self];
		[preferencesToolbar setSelectedItemIdentifier:PREFERENCES_TOOLBAR_GENERAL_ITEM];
		[self setPreferencesContentHeight:PREFERENCES_TOOLBAR_GENERAL_HEIGHT];
	}
	
	[self updatePreferencesFeedReaderPopUp];
	[self updatePreferencesFontTextFields];
	
	[preferencesWindow center];
	[preferencesWindow makeKeyAndOrderFront:self];
	[preferencesWindow makeFirstResponder:[preferencesWindow contentView]];
}

- (IBAction)newWindow:(id)sender {
	[self newWindow];
}

- (IBAction)newTab:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController openNewTab];
	}
}

- (IBAction)closeWindow:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if (keyWin != nil) {
		[keyWin performClose:self];
	}
}

- (IBAction)closeTab:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController closeTab];
	}
}

- (IBAction)openLink:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		CLTabViewItem *tabViewItem = [[windowController tabView] selectedTabViewItem];
		
		if (tabViewItem != nil) {
			NSString *linkString = nil;
			
			if ([tabViewItem tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [tabViewItem timelineView];
				CLTimelineViewItem *timelineViewItem = [timelineView selectedItem];
				
				if (timelineViewItem != nil) {
					linkString = [timelineViewItem postUrl];
				}
				
			} else if ([tabViewItem tabType] == CLClassicType) {
				CLClassicView *classicView = [tabViewItem classicView];
				CLPost *displayedPost = [classicView displayedPost];
				
				if (displayedPost != nil) {
					linkString = [displayedPost link];
				}
			}
			
			if (linkString != nil) {
				NSURL *url = [NSURL URLWithString:linkString];
				NSURLRequest *urlRequest = [NSURLRequest requestWithURL:url];
				[windowController openNewWebTabWith:urlRequest selectTab:YES];
			}
		}
	}
}

- (IBAction)openLinkInBrowser:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		CLTabViewItem *tabViewItem = [[windowController tabView] selectedTabViewItem];
		
		if (tabViewItem != nil) {
			NSString *linkString = nil;
			
			if ([tabViewItem tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [tabViewItem timelineView];
				CLTimelineViewItem *timelineViewItem = [timelineView selectedItem];
				
				if (timelineViewItem != nil) {
					linkString = [timelineViewItem postUrl];
				}
				
			} else if ([tabViewItem tabType] == CLClassicType) {
				CLClassicView *classicView = [tabViewItem classicView];
				CLPost *displayedPost = [classicView displayedPost];
				
				if (displayedPost != nil) {
					linkString = [displayedPost link];
				}
			}
			
			if (linkString != nil) {
				NSURL *url = [NSURL URLWithString:linkString];
				
				BOOL response = [[NSWorkspace sharedWorkspace] openURL:url];
				
				if (response == NO) {
					[CLErrorHelper createAndDisplayError:@"Unable to load URL."];
				}
			}
		}
	}
}

- (IBAction)importOPML:(id)sender {
	
	if ([opmlLoadingWindow isVisible] == NO) {
		NSOpenPanel *openPanel = [NSOpenPanel openPanel];
		[openPanel setAllowsOtherFileTypes:YES];
		[openPanel setResolvesAliases:YES];
		[openPanel setAllowsMultipleSelection:NO];
		[openPanel setCanChooseDirectories:NO];
		[openPanel setCanChooseFiles:YES];
		[openPanel setTitle:@"Import OPML"];
		[openPanel setDirectoryURL:[NSURL URLWithString:@"~/Documents"]];
		
		NSInteger result = [openPanel runModal];
		
		if (result == NSFileHandlingPanelOKButton) {
			NSString *opmlString = [NSString stringWithContentsOfURL:[openPanel URL] usedEncoding:nil error:nil];
			
			if (opmlString == nil) {
				[CLErrorHelper createAndDisplayError:@"There was an error importing the OPML file."];
				
				return;
			}
			
			CLXMLNode *rootNode = [CLXMLParser parseString:opmlString];
			
			if (rootNode == nil) {
				[CLErrorHelper createAndDisplayError:@"There was an error importing the OPML file."];
				
				return;
			}
			
			[opmlLoadingProgressIndicator setUsesThreadedAnimation:YES];
			[opmlLoadingProgressIndicator startAnimation:self];
			[opmlLoadingWindow center];
			[opmlLoadingWindow makeKeyAndOrderFront:self];
			
			[self updateMenuItems];
			
			[self processOPML:rootNode];
			
			[opmlLoadingWindow close];
			[opmlLoadingProgressIndicator stopAnimation:self];
			
			[self updateMenuItems];
			
		}
	}
}

- (IBAction)exportOPML:(id)sender {
	NSSavePanel *savePanel = [NSSavePanel savePanel];
	[savePanel setAllowsOtherFileTypes:YES];
	[savePanel setCanCreateDirectories:YES];
	[savePanel setTitle:@"Export OPML"];
	[savePanel setDirectoryURL:[NSURL URLWithString:@"~/Documents"]];
	
	NSInteger result = [savePanel runModal];
	
	if (result == NSFileHandlingPanelOKButton) {
		NSString *OPMLString = [self OPMLString];
		[OPMLString writeToURL:[savePanel URL] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
}

- (IBAction)classicView:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController changeToClassicViewMode];
	}
}

- (IBAction)timelineView:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController changeToTimelineViewMode];
	}
}

- (IBAction)refreshSubscriptions:(id)sender {
	[self queueAllFeedsSyncRequest];
}

- (IBAction)reloadPage:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		CLTabViewItem *selectedTab = [[windowController tabView] selectedTabViewItem];
		
		if (selectedTab != nil) {
			if ([selectedTab tabType] == CLWebType) {
				CLWebTab *webTab = [selectedTab webTab];
				
				if (webTab != nil) {
					[webTab reload:self];
				}
			}
		}
	}
}

- (IBAction)back:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController back];
	}
}

- (IBAction)forward:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController forward];
	}
}

- (IBAction)addSubscription:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	CLWindowController *windowController;
	
	if ([self isContentWindow:keyWin]) {
		windowController = [keyWin windowController];
	} else {
		windowController = [self newWindow];
	}
	
	[windowController addSubscription:self];
}

- (IBAction)addFolder:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	CLWindowController *windowController;
	
	if ([self isContentWindow:keyWin]) {
		windowController = [keyWin windowController];
	} else {
		windowController = [self newWindow];
	}
	
	[self addFolderWithTitle:nil toFolder:nil forWindow:windowController];
}

- (IBAction)addStar:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		CLTabViewItem *tabViewItem = [[windowController tabView] selectedTabViewItem];
		
		if (tabViewItem != nil) {
			CLPost *post = nil;
			
			if ([tabViewItem tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [tabViewItem timelineView];
				
				if ([timelineView selectedItem] != nil) {
					post = [self postForDbId:[[timelineView selectedItem] postDbId]];
				}
				
			} else if ([tabViewItem tabType] == CLClassicType) {
				CLClassicView *classicView = [tabViewItem classicView];
				
				if ([classicView displayedPost] != nil) {
					post = [classicView displayedPost];
				}
			}
			
			if (post != nil) {
				if (![post isStarred]) {
					[self addStarToPost:post];
				}
			}
		}
	}
}

- (IBAction)removeStar:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		CLTabViewItem *tabViewItem = [[windowController tabView] selectedTabViewItem];
		
		if (tabViewItem != nil) {
			CLPost *post = nil;
			
			if ([tabViewItem tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [tabViewItem timelineView];
				
				if ([timelineView selectedItem] != nil) {
					post = [self postForDbId:[[timelineView selectedItem] postDbId]];
				}
				
			} else if ([tabViewItem tabType] == CLClassicType) {
				CLClassicView *classicView = [tabViewItem classicView];
				
				if ([classicView displayedPost] != nil) {
					post = [classicView displayedPost];
				}
			}
			
			if (post != nil) {
				if ([post isStarred]) {
					[self removeStarFromPost:post];
				}
			}
		}
	}
}

- (IBAction)selectNextTab:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController selectNextTabViewItem];
	}
}

- (IBAction)selectPreviousTab:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	
	if ([self isContentWindow:keyWin]) {
		CLWindowController *windowController = [keyWin windowController];
		[windowController selectPreviousTabViewItem];
	}
}

- (IBAction)acknowledgments:(id)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	CLWindowController *windowController;
	
	if ([self isContentWindow:keyWin]) {
		windowController = [keyWin windowController];
	} else {
		windowController = [self newWindow];
	}
	
	NSBundle *mainBundle = [NSBundle mainBundle];
	NSURL *acknowledgmentsURL = [mainBundle URLForResource:@"Acknowledgments" withExtension:@"html"];
	
	if (acknowledgmentsURL != nil) {
		NSURLRequest *request = [NSURLRequest requestWithURL:acknowledgmentsURL];
		[windowController openNewWebTabWith:request selectTab:YES];
	}
}

- (void)openSubscription:(NSMenuItem *)sender {
	
	if ([sender representedObject] != nil) {
		NSWindow *keyWin = [NSApp keyWindow];
		CLWindowController *windowController;
		
		if ([self isContentWindow:keyWin]) {
			windowController = [keyWin windowController];
		} else {
			windowController = [self newWindow];
		}
		
		if ([windowController selectSourceListItem:[sender representedObject]] == NO) {
			[windowController openItemInCurrentTab:[sender representedObject] orQuery:nil];
		}
	}
}

- (void)openNewItems:(NSMenuItem *)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	CLWindowController *windowController;
	
	if ([self isContentWindow:keyWin]) {
		windowController = [keyWin windowController];
	} else {
		windowController = [self newWindow];
	}
	
	if ([windowController selectSourceListItem:[windowController sourceListNewItems]] == NO) {
		[windowController openItemInCurrentTab:[windowController sourceListNewItems] orQuery:nil];
	}
}

- (void)openStarredItems:(NSMenuItem *)sender {
	NSWindow *keyWin = [NSApp keyWindow];
	CLWindowController *windowController;
	
	if ([self isContentWindow:keyWin]) {
		windowController = [keyWin windowController];
	} else {
		windowController = [self newWindow];
	}
	
	if ([windowController selectSourceListItem:[windowController sourceListStarredItems]] == NO) {
		[windowController openItemInCurrentTab:[windowController sourceListStarredItems] orQuery:nil];
	}
}


#pragma mark menu things

- (BOOL)isContentWindow:(NSWindow *)window {
	if (window != nil && [[window windowController] isKindOfClass:[CLWindowController class]]) {
		return YES;
	}
	
	return NO;
}

- (void)updateMenuItems {
	NSWindow *keyWin = [NSApp keyWindow];
	[self updateMenuItemsUsingWindow:keyWin];
}

- (void)updateMenuItemsUsingWindow:(NSWindow *)window {
	
	[self setWindowForUpdate:window];
	
	for (NSMenuItem *menuItem in [[NSApp mainMenu] itemArray]) {
		[[menuItem submenu] update];
	}
	
	[self setWindowForUpdate:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
	NSWindow *window = [notification object];
	[self updateMenuItemsUsingWindow:window];
}

- (void)windowDidResignKey:(NSNotification *)notification {
	[self updateMenuItems];
}

- (void)windowIsClosing:(NSNotification *)notification {
	NSWindow *window = [notification object];
	[window makeFirstResponder:[window contentView]];
	
	if ([self isContentWindow:window]) {
		CLWindowController *windowController = [window windowController];
		
		if (windowController != nil) {
			[windowControllers removeObject:windowController];
		}
	}
	
	[self performSelector:@selector(updateMenuItemsUsingWindow:) withObject:nil afterDelay:0.25];
}

- (void)updateSubscriptionsMenu {
	[subscriptionsMenu removeAllItems];
	
	NSMenuItem *subscriptionMenuItem = [[NSMenuItem alloc] init];
	[subscriptionMenuItem setTitle:@"Add Subscription..."];
	[subscriptionMenuItem setAction:@selector(addSubscription:)];
	[subscriptionMenuItem setKeyEquivalent:@"d"];
	
	[subscriptionsMenu addItem:subscriptionMenuItem];
	[subscriptionMenuItem release];
	
	NSMenuItem *folderMenuItem = [[NSMenuItem alloc] init];
	[folderMenuItem setTitle:@"Add Folder"];
	[folderMenuItem setAction:@selector(addFolder:)];
	[folderMenuItem setKeyEquivalent:@"N"];
	
	[subscriptionsMenu addItem:folderMenuItem];
	[folderMenuItem release];
	
	[subscriptionsMenu addItem:[NSMenuItem separatorItem]];
	
	NSMenuItem *menuItem = [[NSMenuItem alloc] init];
	[menuItem setTitle:@"New Items"];
	NSString *newItemsIconName = [[NSBundle mainBundle] pathForResource:@"inbox-table" ofType:@"png"];
	NSImage *newItemsIcon = [[[NSImage alloc] initWithContentsOfFile:newItemsIconName] autorelease];
	[menuItem setImage:newItemsIcon];
	[menuItem setAction:@selector(openNewItems:)];
	[menuItem setKeyEquivalent:@"A"];
	
	[subscriptionsMenu addItem:menuItem];
	[menuItem release];
	
	menuItem = [[NSMenuItem alloc] init];
	[menuItem setTitle:@"Starred Items"];
	NSString *starredItemsIconName = [[NSBundle mainBundle] pathForResource:@"star" ofType:@"png"];
	NSImage *starredItemsIcon = [[[NSImage alloc] initWithContentsOfFile:starredItemsIconName] autorelease];
	[menuItem setImage:starredItemsIcon];
	[menuItem setAction:@selector(openStarredItems:)];
	[menuItem setKeyEquivalent:@"G"];
	
	[subscriptionsMenu addItem:menuItem];
	[menuItem release];
	
	if ([subscriptionList count] > 0) {
		[subscriptionsMenu addItem:[NSMenuItem separatorItem]];
	}
	
	[self addSubscriptionsFrom:subscriptionList toMenu:subscriptionsMenu];
}

- (void)addSubscriptionsFrom:(NSMutableArray *)array toMenu:(NSMenu *)menu {
	for (CLSourceListItem *item in array) {
		
		NSImage *itemImage = [item icon];
		[itemImage setFlipped:NO];
		
		if (itemImage == nil) {
			NSString *rssIconName = [[NSBundle mainBundle] pathForResource:@"rssIcon" ofType:@"png"];
			itemImage = [[[NSImage alloc] initWithContentsOfFile:rssIconName] autorelease];
		}
		
		NSImage *imageThumb = [itemImage clThumbnail:NSMakeSize(16, 16)];
		
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		[menuItem setTitle:[item extractTitleForDisplay]];
		[menuItem setImage:imageThumb];
		
		if ([item isKindOfClass:[CLSourceListFeed class]]) {
			[menuItem setRepresentedObject:item];
			[menuItem setAction:@selector(openSubscription:)];
		} else if ([item isKindOfClass:[CLSourceListFolder class]]) {
			NSMenu *submenu = [[NSMenu alloc] initWithTitle:[item title]];
			[self addSubscriptionsFrom:[item children] toMenu:submenu];
			[menuItem setSubmenu:submenu];
			[submenu release];
		}
		
		[menu addItem:menuItem];
		[menuItem release];
	}
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem {
	
	NSWindow *window;
	
	if (windowForUpdate) {
		window = windowForUpdate;
	} else {
		window = [NSApp keyWindow];
	}
	
	NSWindowController *windowController = [window windowController];
	CLTabViewItem *selectedTab = nil;
	
	if ([self isContentWindow:window]) {
		selectedTab = [[(CLWindowController *)windowController tabView] selectedTabViewItem];
	}
	
	if ([anItem action] == @selector(newTab:)) {
		
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		return YES;
	}
	
	if ([anItem action] == @selector(closeWindow:)) {
		[(NSMenuItem *)anItem setKeyEquivalentModifierMask:NSCommandKeyMask];
		[(NSMenuItem *)anItem setKeyEquivalent:@"w"];
		
		if (window == nil) {
			return NO;
		}
		
		if ([self isContentWindow:window] && [(CLWindowController *)windowController numberOfTabViewItems] >= 2) {
			[(NSMenuItem *)anItem setKeyEquivalent:@"W"];
		}
		
		return YES;
	}
	
	if ([anItem action] == @selector(closeTab:)) {
		[(NSMenuItem *)anItem setKeyEquivalentModifierMask:NSCommandKeyMask];
		
		if ([self isContentWindow:window] == NO) {
			[(NSMenuItem *)anItem setKeyEquivalent:@""];
			return NO;
		}
		
		if ([(CLWindowController *)windowController numberOfTabViewItems] < 2) {
			[(NSMenuItem *)anItem setKeyEquivalent:@""];
			return NO;
		} else {
			[(NSMenuItem *)anItem setKeyEquivalent:@"w"];
			return YES;
		}
	}
	
	if ([anItem action] == @selector(openLink:) || [anItem action] == @selector(openLinkInBrowser:)) {
		
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if ([anItem action] == @selector(openLink:) && [[window firstResponder] isKindOfClass:[NSTextView class]]) {
			return NO;
		}
		
		if (selectedTab != nil) {
			NSString *linkString = nil;
			
			if ([selectedTab tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [selectedTab timelineView];
				CLTimelineViewItem *timelineViewItem = [timelineView selectedItem];
				
				if (timelineViewItem != nil) {
					linkString = [timelineViewItem postUrl];
				}
				
			} else if ([selectedTab tabType] == CLClassicType) {
				CLClassicView *classicView = [selectedTab classicView];
				CLPost *displayedPost = [classicView displayedPost];
				
				if (displayedPost != nil) {
					linkString = [displayedPost link];
				}
			}
			
			if (linkString != nil) {
				return YES;
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(importOPML:)) {
		
		if ([opmlLoadingWindow isVisible]) {
			return NO;
		}
		
		return YES;
	}
	
	if ([anItem action] == @selector(timelineView:)) {
		
		[(NSMenuItem *)anItem setState:NSOffState];
		
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if ([[window windowController] viewMode] == CLTimelineViewMode) {
			[(NSMenuItem *)anItem setState:NSOnState];
		}
		
		if (selectedTab != nil) {
			if ([selectedTab tabType] == CLTimelineType || [selectedTab tabType] == CLClassicType) {
				return YES;
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(classicView:)) {
		
		[(NSMenuItem *)anItem setState:NSOffState];
		
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if ([[window windowController] viewMode] == CLClassicViewMode) {
			[(NSMenuItem *)anItem setState:NSOnState];
		}
		
		if (selectedTab != nil) {
			if ([selectedTab tabType] == CLTimelineType || [selectedTab tabType] == CLClassicType) {
				return YES;
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(reloadPage:)) {
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if (selectedTab != nil) {
			if ([selectedTab tabType] == CLWebType) {
				return YES;
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(back:)) {
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if (selectedTab != nil) {
			if ([selectedTab tabType] == CLWebType) {
				CLWebTab *webTab = [selectedTab webTab];
				
				if (webTab != nil) {
					CLWebView *webView = [webTab webView];
					
					if (webView != nil) {
						if ([webView canGoBack]) {
							return YES;
						}
					}
				}
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(forward:)) {
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if (selectedTab != nil) {
			if ([selectedTab tabType] == CLWebType) {
				CLWebTab *webTab = [selectedTab webTab];
				
				if (webTab != nil) {
					CLWebView *webView = [webTab webView];
					
					if (webView != nil) {
						if ([webView canGoForward]) {
							return YES;
						}
					}
				}
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(addStar:) || [anItem action] == @selector(removeStar:)) {
		
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if (selectedTab != nil) {
			NSInteger selectedItemDbId = 0;
			
			if ([selectedTab tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [selectedTab timelineView];
				CLTimelineViewItem *timelineViewItem = [timelineView selectedItem];
				
				if (timelineViewItem != nil) {
					selectedItemDbId = [timelineViewItem postDbId];
				}
				
			} else if ([selectedTab tabType] == CLClassicType) {
				CLClassicView *classicView = [selectedTab classicView];
				CLPost *displayedPost = [classicView displayedPost];
				
				if (displayedPost != nil) {
					selectedItemDbId = [displayedPost dbId];
				}
			}
			
			if (selectedItemDbId > 0) {
				CLPost *post = [self postForDbId:selectedItemDbId];
				
				if ([post isStarred] == NO && [anItem action] == @selector(addStar:)) {
					return YES;
				} else if ([post isStarred] == YES && [anItem action] == @selector(removeStar:)) {
					return YES;
				}
			}
		}
		
		return NO;
	}
	
	if ([anItem action] == @selector(selectNextTab:) || [anItem action] == @selector(selectPreviousTab:)) {
		if ([self isContentWindow:window] == NO) {
			return NO;
		}
		
		if ([(CLWindowController *)windowController numberOfTabViewItems] < 2) {
			return NO;
		}
		
		return YES;
	}
	
	return YES;
}


#pragma mark Preferences window

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
	
	NSToolbarItem *toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];
	
	if ([itemIdentifier isEqual:PREFERENCES_TOOLBAR_GENERAL_ITEM]) {
		[toolbarItem setLabel:@"General"];
		[toolbarItem setImage:[NSImage imageNamed:@"NSPreferencesGeneral"]];
	} else if ([itemIdentifier isEqual:PREFERENCES_TOOLBAR_FONTS_ITEM]) {
		[toolbarItem setLabel:@"Fonts"];
		[toolbarItem setImage:[NSImage imageNamed:@"ToolbarItemFonts.tiff"]];
	}
	
	[toolbarItem setTarget:self];
	[toolbarItem setAction:@selector(toolbarItemSelected:)];
	
	return toolbarItem;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
	return preferencesToolbarItems;
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
	return preferencesToolbarItems;
}

- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar {
	return preferencesToolbarItems;
}

- (void)toolbarItemSelected:(NSToolbarItem *)toolbarItem {
	[preferencesTabView setHidden:YES];
	
	NSInteger contentHeight = 0;
	
	if ([[toolbarItem itemIdentifier] isEqual:PREFERENCES_TOOLBAR_GENERAL_ITEM]) {
		contentHeight = PREFERENCES_TOOLBAR_GENERAL_HEIGHT;
	} else if ([[toolbarItem itemIdentifier] isEqual:PREFERENCES_TOOLBAR_FONTS_ITEM]) {
		contentHeight = PREFERENCES_TOOLBAR_FONTS_HEIGHT;
	}
	
	NSInteger heightDifference = contentHeight - preferencesContentHeight;
	NSRect oldFrame = [preferencesWindow frame];
	NSRect newFrame = NSMakeRect(oldFrame.origin.x, oldFrame.origin.y - heightDifference, oldFrame.size.width, oldFrame.size.height + heightDifference);
	
	[preferencesWindow setFrame:newFrame display:YES animate:YES];
	
	[self setPreferencesContentHeight:contentHeight];
	
	NSInteger indexOfSelectedItem = [preferencesToolbarItems indexOfObject:[toolbarItem itemIdentifier]];
	[preferencesTabView selectTabViewItemAtIndex:indexOfSelectedItem];
	[preferencesTabView setHidden:NO];
	
	[preferencesWindow makeFirstResponder:[preferencesWindow contentView]];
	
	NSFontManager *fontManager = [NSFontManager sharedFontManager];
	[[fontManager fontPanel:YES] close];
}

- (IBAction)preferencesSelectHeadlineFont:(id)sender {
	[preferencesWindow setIsSelectingHeadlineFont:YES];
	[preferencesWindow setIsSelectingBodyFont:NO];
	
	NSFont *headlineFont = [NSFont fontWithName:preferenceHeadlineFontName size:preferenceHeadlineFontSize];
	
	NSFontManager *fontManager = [NSFontManager sharedFontManager];
	[fontManager setSelectedFont:headlineFont isMultiple:NO];
	[fontManager orderFrontFontPanel:self];
}

- (IBAction)preferencesSelectBodyFont:(id)sender {
	[preferencesWindow setIsSelectingHeadlineFont:NO];
	[preferencesWindow setIsSelectingBodyFont:YES];
	
	NSFont *bodyFont = [NSFont fontWithName:preferenceBodyFontName size:preferenceBodyFontSize];
	
	NSFontManager *fontManager = [NSFontManager sharedFontManager];
	[fontManager setSelectedFont:bodyFont isMultiple:NO];
	[fontManager orderFrontFontPanel:self];
}

- (void)preferencesSetDefaultFeedReader:(NSMenuItem *)menuItem {
	NSString *bundleId = [menuItem representedObject];
	
	if (bundleId != nil && [bundleId length] > 0) {
		[CLLaunchServicesHelper setDefaultHandlerForUrlScheme:@"feed" bundleId:bundleId];
		
		[self updatePreferencesFeedReaderPopUp];
	}
}

- (void)preferencesSelectOtherApplication:(NSMenuItem *)menuItem {
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	[openPanel setAllowedFileTypes:[NSArray arrayWithObject:@"app"]];
	[openPanel setDirectoryURL:[NSURL URLWithString:@"~/Applications"]];
	
	void (^preferencesCompletionBlock)(NSInteger) = ^(NSInteger result) {
		if (result == NSFileHandlingPanelOKButton) {
			NSURL *appurl = [openPanel URL];
			NSBundle *appBundle = [NSBundle bundleWithURL:appurl];
			NSString *bundleId = [appBundle bundleIdentifier];
			[CLLaunchServicesHelper setDefaultHandlerForUrlScheme:@"feed" bundleId:bundleId];
			
			[self updatePreferencesFeedReaderPopUp];
		}
	};
	
	[openPanel beginSheetModalForWindow:preferencesWindow completionHandler:preferencesCompletionBlock];
}

- (void)updatePreferencesFeedReaderPopUp {
	NSMenu *feedReaderMenu = [preferencesFeedReaderPopUp menu];
	
	// before we clear the menu, we need to release some stuff
	// otherwise, represented objects would leak
	if ([feedReaderMenu numberOfItems] > 0) {
		NSArray *menuItems = [feedReaderMenu itemArray];
		
		for (NSMenuItem *menuItem in menuItems) {
			if ([menuItem representedObject] != nil) {
				[[menuItem representedObject] release];
				[menuItem setRepresentedObject:nil];
			}
		}
		
		[feedReaderMenu removeAllItems];
	}
	
	NSMenuItem *menuItem;
	NSString *feedReaderName;
	NSImage *feedReaderImage;
	NSString *defaultReaderBundleId = [CLLaunchServicesHelper defaultHandlerForUrlScheme:@"feed"];
	
	if (defaultReaderBundleId != nil) {
		feedReaderName = [CLLaunchServicesHelper nameForBundleId:defaultReaderBundleId];
		feedReaderImage = [CLLaunchServicesHelper iconForBundleId:defaultReaderBundleId];
		
		if (feedReaderName != nil && feedReaderImage != nil) {
			[feedReaderImage setSize:NSMakeSize(16, 16)];
			
			menuItem = [[NSMenuItem alloc] init];
			[menuItem setTitle:feedReaderName];
			[menuItem setImage:feedReaderImage];
			[feedReaderMenu addItem:menuItem];
			[menuItem release];
			
			[feedReaderMenu addItem:[NSMenuItem separatorItem]];
		}
	}
	
	NSArray *readerBundleIds = [CLLaunchServicesHelper allHandlersForUrlScheme:@"feed"];
	NSMutableDictionary *iconDict = [[NSMutableDictionary alloc] init];
	NSMutableDictionary *bundleIdDict = [[NSMutableDictionary alloc] init];
	
	if (readerBundleIds != nil) {
		for (NSString *bundleId in readerBundleIds) {
			if ([bundleId isEqual:defaultReaderBundleId] == NO) {
				feedReaderName = [CLLaunchServicesHelper nameForBundleId:bundleId];
				feedReaderImage = [CLLaunchServicesHelper iconForBundleId:bundleId];

				if (feedReaderName != nil && feedReaderImage != nil) {
					[feedReaderImage setSize:NSMakeSize(16, 16)];
					
					[iconDict setValue:feedReaderImage forKey:feedReaderName];
					[bundleIdDict setValue:bundleId forKey:feedReaderName];
				}
			}
		}
	}
	
	NSArray *readerNames = [iconDict allKeys];
	readerNames = [readerNames sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	
	for (NSString *readerName in readerNames) {
		menuItem = [[NSMenuItem alloc] init];
		[menuItem setTitle:readerName];
		[menuItem setImage:[iconDict objectForKey:readerName]];
		[menuItem setTarget:self];
		[menuItem setAction:@selector(preferencesSetDefaultFeedReader:)];
		[menuItem setRepresentedObject:[[bundleIdDict objectForKey:readerName] retain]];
		[feedReaderMenu addItem:menuItem];
		[menuItem release];
	}
	
	[iconDict release];
	[bundleIdDict release];
	
	[feedReaderMenu addItem:[NSMenuItem separatorItem]];
	
	menuItem = [[NSMenuItem alloc] init];
	[menuItem setTitle:@"Select..."];
	[menuItem setTarget:self];
	[menuItem setAction:@selector(preferencesSelectOtherApplication:)];
	[feedReaderMenu addItem:menuItem];
	[menuItem release];
}

- (void)updatePreferencesFontTextFields {
	NSFont *headlineFont = [NSFont fontWithName:preferenceHeadlineFontName size:preferenceHeadlineFontSize];
	
	NSString *nameDisplay = [headlineFont displayName];
	NSString *sizeDisplay = [NSString stringWithFormat:@"%.1f", preferenceHeadlineFontSize];
	
	if ([sizeDisplay hasSuffix:@".0"]) {
		sizeDisplay = [sizeDisplay substringToIndex:([sizeDisplay length] - 2)];
	}
	
	[preferencesHeadlineTextField setStringValue:[NSString stringWithFormat:@"%@ %@", nameDisplay, sizeDisplay]];
	
	NSFont *bodyFont = [NSFont fontWithName:preferenceBodyFontName size:preferenceBodyFontSize];
	
	nameDisplay = [bodyFont displayName];
	sizeDisplay = [NSString stringWithFormat:@"%.1f", preferenceBodyFontSize];
	
	if ([sizeDisplay hasSuffix:@".0"]) {
		sizeDisplay = [sizeDisplay substringToIndex:([sizeDisplay length] - 2)];
	}
	
	[preferencesBodyTextField setStringValue:[NSString stringWithFormat:@"%@ %@", nameDisplay, sizeDisplay]];
}

- (void)updateContentFonts {
	for (CLWindowController *windowController in windowControllers) {
		CLTabView *tabView = [windowController tabView];
		
		for (CLTabViewItem *tabViewItem in [tabView tabViewItems]) {
			if ([tabViewItem tabType] == CLTimelineType) {
				CLTimelineView *timelineView = [tabViewItem timelineView];
				
				for (CLTimelineViewItem *timelineViewItem in [timelineView timelineViewItems]) {
					[windowController updateWebView:[timelineViewItem webView] headlineFontName:preferenceHeadlineFontName headlineFontSize:preferenceHeadlineFontSize bodyFontName:preferenceBodyFontName bodyFontSize:preferenceBodyFontSize];
					[timelineViewItem updateHeight];
				}
				
				[timelineView updateSubviewRects];
				[timelineView setNeedsDisplay:YES];
				
			} else if ([tabViewItem tabType] == CLClassicType) {
				CLClassicView *classicView = [tabViewItem classicView];
				
				[windowController updateWebView:[classicView webView] headlineFontName:preferenceHeadlineFontName headlineFontSize:preferenceHeadlineFontSize bodyFontName:preferenceBodyFontName bodyFontSize:preferenceBodyFontSize];
			}
		}
	}
}

- (void)defaultsChanged:(NSNotification *)notification {
	if (inLiveResize == NO) {
		[self readPreferencesAndUpdate];
	}
}

- (void)readPreferencesAndUpdate {
	
	NSInteger checkForNewArticles = [[NSUserDefaults standardUserDefaults] integerForKey:PREFERENCES_CHECK_FOR_NEW_ARTICLES_KEY];
	
	if (checkForNewArticles != preferenceCheckForNewArticles) {
		[self setPreferenceCheckForNewArticles:checkForNewArticles];
		
		[self updateFeedSyncStatus];
	}
	
	NSInteger removeArticles = [[NSUserDefaults standardUserDefaults] integerForKey:PREFERENCES_REMOVE_ARTICLES_KEY];
	
	if (removeArticles != preferenceRemoveArticles) {
		[self setPreferenceRemoveArticles:removeArticles];
		[self removeOldArticles];
	}
	
	NSInteger markArticlesAsRead = [[NSUserDefaults standardUserDefaults] integerForKey:PREFERENCES_MARK_ARTICLES_AS_READ_KEY];
	
	if (markArticlesAsRead != preferenceMarkArticlesAsRead) {
		[self setPreferenceMarkArticlesAsRead:markArticlesAsRead];
		[self markArticlesAsRead];
	}
	
	BOOL displayUnreadCountInDock = [[NSUserDefaults standardUserDefaults] boolForKey:PREFERENCES_DISPLAY_UNREAD_COUNT_IN_DOCK_KEY];
	
	if (displayUnreadCountInDock != preferenceDisplayUnreadCountInDock) {
		[self setPreferenceDisplayUnreadCountInDock:displayUnreadCountInDock];
		[self updateDockTile];
	}
}


#pragma mark CLPreferencesWindowDelegate

- (void)preferencesWindowUserDidSelectHeadlineFont:(NSFont *)font {
	[self setPreferenceHeadlineFontName:[font fontName]];
	[self setPreferenceHeadlineFontSize:[font pointSize]];
	
	[SyndicationAppDelegate miscellaneousSetValue:preferenceHeadlineFontName forKey:MISCELLANEOUS_HEADLINE_FONT_NAME];
	[SyndicationAppDelegate miscellaneousSetValue:[[NSNumber numberWithDouble:preferenceHeadlineFontSize] stringValue] forKey:MISCELLANEOUS_HEADLINE_FONT_SIZE];
	
	[self updatePreferencesFontTextFields];
	[self updateContentFonts];
}

- (void)preferencesWindowUserDidSelectBodyFont:(NSFont *)font {
	[self setPreferenceBodyFontName:[font fontName]];
	[self setPreferenceBodyFontSize:[font pointSize]];
	
	[SyndicationAppDelegate miscellaneousSetValue:preferenceBodyFontName forKey:MISCELLANEOUS_BODY_FONT_NAME];
	[SyndicationAppDelegate miscellaneousSetValue:[[NSNumber numberWithDouble:preferenceBodyFontSize] stringValue] forKey:MISCELLANEOUS_BODY_FONT_SIZE];
	
	[self updatePreferencesFontTextFields];
	[self updateContentFonts];
}


#pragma mark feed:// urls

- (void)handleFeedEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSString *urlStr = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
	
	if ([[urlStr substringToIndex:7] isEqual:@"feed://"]) {
		urlStr = [NSString stringWithFormat:@"http://%@", [urlStr substringFromIndex:7]];
	}
	
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert setMessageText:[NSString stringWithFormat:@"Add subscription to %@?", urlStr]];
	[alert setAlertStyle:NSInformationalAlertStyle];
	
	if ([alert runModal] == NSAlertFirstButtonReturn) {
		
		// check to see if this feed already exists in the database
		FMDatabase *db = [FMDatabase databaseWithPath:[CLDatabaseHelper pathForDatabaseFile]];
		
		if (![db open]) {
			[CLErrorHelper createAndDisplayError:@"Unable to add subscription!"];
			return;
		}
		
		FMResultSet *rs = [db executeQuery:@"SELECT * FROM feed WHERE Url=? AND IsHidden=0", urlStr];
		
		if ([rs next]) {
			[CLErrorHelper createAndDisplayError:@"The subscription could not be added because it already exists in your library!"];
			[rs close];
			[db close];
			return;
		}
		
		[rs close];
		[db close];
		
		if (hasFinishedLaunching) {
			[self addSubscriptionForUrlString:urlStr withTitle:nil toFolder:nil refreshImmediately:YES];
		} else {
			[self setFeedEventString:urlStr];
		}
	}
}


# pragma mark window notifications

- (void)windowWillStartLiveResize:(NSNotification *)notification {
	[self setInLiveResize:YES];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
	[self setInLiveResize:NO];
	[self readPreferencesAndUpdate];
}

@end

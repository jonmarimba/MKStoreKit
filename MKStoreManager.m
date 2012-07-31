//
//  MKStoreManager.m
//  MKStoreKit (Version 4.0)
//
//  Created by Mugunth Kumar on 17-Nov-2010.
//  Version 4.1
//  Copyright 2010 Steinlogic. All rights reserved.
//	File created using Singleton XCode Template by Mugunth Kumar (http://mugunthkumar.com
//  Permission granted to do anything, commercial/non-commercial with this file apart from removing the line/URL above
//  Read my blog post at http://mk.sg/1m on how to use this code

//  Licensing (Zlib)
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//  3. This notice may not be removed or altered from any source distribution.

//  As a side note on using this code, you might consider giving some credit to me by
//	1) linking my website from your app's website
//	2) or crediting me inside the app's credits page
//	3) or a tweet mentioning @mugunthkumar
//	4) A paypal donation to mugunth.kumar@gmail.com

#import "MKStoreManager.h"
#import "SFHFKeychainUtils.h"
#import "MKSKSubscriptionProduct.h"
#import "MKSKProduct.h"
#import "Reachability.h"

NSString *kStoreKitItemTypeConsumables = @"Consumables";
NSString *kStoreKitItemTypeNonConsumables = @"Non-Consumables";
NSString *kStoreKitItemTypeSubscriptions = @"Subscriptions";

static NSMutableDictionary *skItems;

@interface MKStoreManager () //private methods and properties

@property (nonatomic, copy) void (^onTransactionCancelled)();
@property (nonatomic, copy) void (^onTransactionCompleted)(NSString *productId, NSData* receiptData);

@property (nonatomic, copy) void (^onRestoreFailed)(NSError* error);
@property (nonatomic, copy) void (^onRestoreCompleted)();

@property (nonatomic, retain) NSMutableArray *purchasableObjects;
@property (nonatomic, retain) NSMutableDictionary *subscriptionProducts;
@property (nonatomic, retain) Reachability *reachability;
@property (nonatomic, retain) MKStoreObserver *storeObserver;
@property (nonatomic, retain) SKProductsRequest *currentRequest;
@property (nonatomic, assign) BOOL productsAvailable;

- (void) requestProductData;
- (void) startVerifyingSubscriptionReceipts;
- (void) rememberPurchaseOfProduct:(NSString*) productIdentifier withReceipt:(NSData*) receiptData;
- (void) addToQueue:(NSString*) productId;

@end

@implementation MKStoreManager


static MKStoreManager* _sharedStoreManager;

-(BOOL)fetchingProducts
{
    return [self currentRequest] != nil;
}

+(BOOL) iCloudAvailable {
    return NO; //JS: seems like a bad idea to put this data in iCloud
}

+(void) setObject:(id) object forKey:(NSString*) key
{
    NSString *objectString = nil;
    if ([object isKindOfClass:[NSString class]])
    {
        objectString = object;
    }
    else if([object isKindOfClass:[NSData class]])
    {
        objectString = [[[NSString alloc] initWithData:object encoding:NSUTF8StringEncoding] autorelease];
    }
    else if([object isKindOfClass:[NSNumber class]])
    {
        objectString = [(NSNumber*)object stringValue];
    }
    NSError *error = nil;
    [SFHFKeychainUtils storeUsername:key
                         andPassword:objectString
                      forServiceName:@"MKStoreKit"
                      updateExisting:YES
                               error:&error];

    if(error)
        NSLog(@"%@", [error localizedDescription]);

    if([self iCloudAvailable]) {
        [[NSUbiquitousKeyValueStore defaultStore] setObject:objectString forKey:key];
        [[NSUbiquitousKeyValueStore defaultStore] synchronize];
    }
}

+(id) receiptForKey:(NSString*) key {

    NSData *receipt = [MKStoreManager objectForKey:key];
    if(!receipt)
        receipt = [MKStoreManager objectForKey:[NSString stringWithFormat:@"%@-receipt", key]];

    return receipt;
}

+(id) objectForKey:(NSString*) key
{
    NSError *error = nil;
    NSObject *object = [SFHFKeychainUtils getPasswordForUsername:key
                                                  andServiceName:@"MKStoreKit"
                                                           error:&error];
    if(error)
        NSLog(@"%@", [error localizedDescription]);

    return object;
}

+(NSNumber*) numberForKey:(NSString*) key
{
    return [NSNumber numberWithInt:[[MKStoreManager objectForKey:key] intValue]];
}

+(NSData*) dataForKey:(NSString*) key
{
    NSString *str = [MKStoreManager objectForKey:key];
    return [str dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark Singleton Methods

+ (MKStoreManager*)sharedManager
{
	if(!_sharedStoreManager) {
		static dispatch_once_t oncePredicate;
		dispatch_once(&oncePredicate, ^{
			_sharedStoreManager = [[super allocWithZone:nil] init];
        });

#if TARGET_IPHONE_SIMULATOR
        NSLog(@"You are running in the Simulator; IAP works only on devices");
#else
        _sharedStoreManager = [[self alloc] init];
        _sharedStoreManager.purchasableObjects = [NSMutableArray array];
        _sharedStoreManager.storeObserver = [[[MKStoreObserver alloc] init] autorelease];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:_sharedStoreManager.storeObserver];


        if([self iCloudAvailable])
            [[NSNotificationCenter defaultCenter] addObserver:_sharedStoreManager
                                                     selector:@selector(updateFromiCloud:)
                                                         name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                                                       object:nil];
        [_sharedStoreManager updateNetworkStatus];
#endif
    }
    return _sharedStoreManager;
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

#pragma mark internet Connection Status
- (void)updateNetworkStatus
{
    if(![self reachability])
    {
        [self setReachability:[Reachability reachabilityForInternetConnection]];
        // Observe the kNetworkReachabilityChangedNotification. When that notification is posted, the
        // method "reachabilityChanged" will be called.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(reachabilityChanged:)
                                                     name:kReachabilityChangedNotification
                                                   object:nil];
        [self.reachability startNotifier];
    }
    if ([self.reachability currentReachabilityStatus] > 0)
    {
        [self requestProductData];
        [self startVerifyingSubscriptionReceipts];
    }
}

-(void)reachabilityChanged:(NSNotification *)note
{
    [self updateNetworkStatus];
}

- (id)retain
{
    return self;
}

- (unsigned)retainCount
{
    return UINT_MAX;  //denotes an object that cannot be released
}

- (oneway void)release
{
    //do nothing
}

- (id)autorelease
{
    return self;
}

#pragma mark Internal MKStoreKit functions

-(NSMutableDictionary*) storeKitItems
{
    return [[self class] storeKitItems];
}

+(NSMutableDictionary *)storeKitItems
{
	if (!skItems)
	{
        NSString *plistPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
                               @"MKStoreKitConfigs.plist"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath])
        {
            skItems = [[NSMutableDictionary alloc] initWithContentsOfFile:plistPath];
        }
        else
        {
            skItems = [[NSMutableDictionary alloc] init];
        }
	}
    return skItems;
}

//removes all store kit items and reloads the plist, if any.
+ (void)resetStoreKitItemsToDefault;
{
    [skItems release]; skItems = nil;
    [self storeKitItems];
}

//TODO: JS: Implementation of these
//+ (void)addConsumableStoreKitItem:(NSString *)itemID withName:(NSString *)name quantity:(NSUInteger)count;
//{
//    NSAssert(NO, @"Not implemented");
//}
//
//+ (void)addSubscriptionStoreKitItem:(NSString *)itemID withSubscriptionDays:(NSUInteger)identifier;
//{
//    NSAssert(NO, @"Not implemented");
//}

+ (void)addNonConsumableStoreKitItem:(NSString *)itemID;
{
    NSMutableDictionary *storeKitItems = [self storeKitItems];
    NSMutableSet *nonConsumables = [NSMutableSet setWithArray:[self nonConsumables]];
    [nonConsumables addObject:itemID];
    NSArray *nonConsumablesReplacementArray = [nonConsumables allObjects];
    [storeKitItems setValue:nonConsumablesReplacementArray forKey:kStoreKitItemTypeNonConsumables];
}

- (void) restorePreviousTransactionsOnComplete:(void (^)(void)) completionBlock
                                       onError:(void (^)(NSError*)) errorBlock
{
    self.onRestoreCompleted = completionBlock;
    self.onRestoreFailed = errorBlock;

	[[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

-(void) restoreCompleted
{
    if(self.onRestoreCompleted)
        self.onRestoreCompleted();
    self.onRestoreCompleted = nil;
}

-(void) restoreFailedWithError:(NSError*) error
{
    if(self.onRestoreFailed)
        self.onRestoreFailed(error);
    self.onRestoreFailed = nil;
}

+(NSArray *)consumables
{
    return [[[self storeKitItems] objectForKey:kStoreKitItemTypeConsumables] allKeys];
}

+(NSArray *)nonConsumables
{
    return [[self storeKitItems] objectForKey:kStoreKitItemTypeNonConsumables];
}

+(NSArray *)subscriptions
{
    return [[[self storeKitItems] objectForKey:@"Subscriptions"] allKeys];
}

-(void) requestProductData
{
    if (![self currentRequest])
    {

        NSMutableArray *productsArray = [NSMutableArray array];

        [productsArray addObjectsFromArray:[[self class] consumables]];
        [productsArray addObjectsFromArray:[[self class] nonConsumables]];
        [productsArray addObjectsFromArray:[[self class] subscriptions]];

        SKProductsRequest *request= [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithArray:productsArray]];
        request.delegate = self;
        [self setCurrentRequest:request];

        [request start];
    }
}

+ (BOOL) removeAllKeychainData {
    NSMutableArray *productsArray = [NSMutableArray array];

    [productsArray addObjectsFromArray:[self consumables]];
    [productsArray addObjectsFromArray:[self nonConsumables]];
    [productsArray addObjectsFromArray:[self subscriptions]];

    int itemCount = productsArray.count;
    NSError *error = nil;

    //loop through all the saved keychain data and remove it
    for (int i = 0; i < itemCount; i++ ) {
        [SFHFKeychainUtils deleteItemForUsername:[productsArray objectAtIndex:i] andServiceName:@"MKStoreKit" error:&error];
    }
    if (!error) {
        return YES;
    }
    else {
        return NO;
    }
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
    NSMutableArray *mutablePurchasableObjects = [self.purchasableObjects mutableCopy];
	[mutablePurchasableObjects addObjectsFromArray:response.products];
    self.purchasableObjects = [NSArray arrayWithArray:mutablePurchasableObjects];
    [mutablePurchasableObjects release];
#ifndef NDEBUG
	for(int i=0;i<[self.purchasableObjects count];i++)
	{
		SKProduct *product = [self.purchasableObjects objectAtIndex:i];
		NSLog(@"Feature: %@, Cost: %f, ID: %@",[product localizedTitle],
			  [[product price] doubleValue], [product productIdentifier]);
	}

	for(NSString *invalidProduct in response.invalidProductIdentifiers)
		NSLog(@"Problem in iTunes connect configuration for product: %@", invalidProduct);
#endif

	[self setCurrentRequest:nil];
	[self setProductsAvailable:([self.purchasableObjects count] > 0)];
    [[NSNotificationCenter defaultCenter] postNotificationName:kProductFetchedNotification
                                                        object:[NSNumber numberWithBool:self.productsAvailable]];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error
{
    [self setCurrentRequest:nil];
	[self setProductsAvailable:NO];

    [[NSNotificationCenter defaultCenter] postNotificationName:kProductFetchedNotification
                                                        object:[NSNumber numberWithBool:self.productsAvailable]];
}

// call this function to check if the user has already purchased your feature
+ (BOOL) isFeaturePurchased:(NSString*) featureId
{
    return [[MKStoreManager numberForKey:featureId] boolValue];
}

- (BOOL) isSubscriptionActive:(NSString*) featureId
{
    MKSKSubscriptionProduct *subscriptionProduct = [self.subscriptionProducts objectForKey:featureId];
    return [subscriptionProduct isSubscriptionActive];
}

// Call this function to populate your UI
// this function automatically formats the currency based on the user's locale

- (NSArray*) purchasableObjectsDescription
{
	NSMutableArray *productDescriptions = [[NSMutableArray alloc] initWithCapacity:[self.purchasableObjects count]];
	for(int i=0;i<[self.purchasableObjects count];i++)
	{
		SKProduct *product = [self.purchasableObjects objectAtIndex:i];

		NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
		[numberFormatter setFormatterBehavior:NSNumberFormatterBehavior10_4];
		[numberFormatter setNumberStyle:NSNumberFormatterCurrencyStyle];
		[numberFormatter setLocale:product.priceLocale];
		NSString *formattedString = [numberFormatter stringFromNumber:product.price];
		[numberFormatter release];

		// you might probably need to change this line to suit your UI needs
		NSString *description = [NSString stringWithFormat:@"%@ (%@)",[product localizedTitle], formattedString];

#ifndef NDEBUG
		NSLog(@"Product %d - %@", i, description);
#endif
		[productDescriptions addObject: description];
	}
	return [NSArray arrayWithArray:[productDescriptions autorelease]];
}

/*Call this function to get a dictionary with all prices of all your product identifers

 For example,

 NSDictionary *prices = [[MKStoreManager sharedManager] pricesDictionary];

 NSString *upgradePrice = [prices objectForKey:@"com.mycompany.upgrade"]

 */
- (NSDictionary *)pricesDictionary {
    NSMutableDictionary *priceDict = [NSMutableDictionary dictionary];
	for(int i=0;i<[self.purchasableObjects count];i++)
	{
		SKProduct *product = [self.purchasableObjects objectAtIndex:i];

		NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
		[numberFormatter setFormatterBehavior:NSNumberFormatterBehavior10_4];
		[numberFormatter setNumberStyle:NSNumberFormatterCurrencyStyle];
		[numberFormatter setLocale:product.priceLocale];
		NSString *formattedString = [numberFormatter stringFromNumber:product.price];
		[numberFormatter release];

        NSString *priceString = [NSString stringWithFormat:@"%@", formattedString];
        [priceDict setObject:priceString forKey:product.productIdentifier];

    }
    return [NSDictionary dictionaryWithDictionary:priceDict];
}

-(void) showAlertWithTitle:(NSString*) title message:(NSString*) message {

#if TARGET_OS_IPHONE
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:NSLocalizedString(@"Dismiss", @"")
                                          otherButtonTitles:nil];
    [alert show];
    [alert autorelease];
#elif TARGET_OS_MAC
    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:NSLocalizedString(@"Dismiss", @"")];

    [alert setMessageText:title];
    [alert setInformativeText:message];
    [alert setAlertStyle:NSInformationalAlertStyle];

    [alert runModal];

#endif
}

- (void) buyFeature:(NSString*) featureId
         onComplete:(void (^)(NSString*, NSData*)) completionBlock
        onCancelled:(void (^)(void)) cancelBlock
{
    self.onTransactionCompleted = completionBlock;
    self.onTransactionCancelled = cancelBlock;
#if TARGET_IPHONE_SIMULATOR
    NSLog(@"On Simulator.  Simulating purchase of %@", featureId);
    [self rememberPurchaseOfProduct:featureId withReceipt:nil];
    if(self.onTransactionCompleted)
        self.onTransactionCompleted(featureId, nil);
#else
    [self addToQueue:featureId];
#endif
}

-(void) addToQueue:(NSString*) productId
{
    static const NSUInteger addQueueMaxRetries = 6;
    static NSUInteger addQueueRetries;
    if ([SKPaymentQueue canMakePayments] && addQueueRetries < addQueueMaxRetries)
	{
        if ([self productsAvailable])
        {
            NSArray *purchableObjects = [self purchasableObjects];
            purchableObjects = [purchableObjects filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF.productIdentifier = %@", productId]];
            SKPayment *payment = nil;
            if ([purchableObjects count])
            {
                SKProduct *product = [purchableObjects objectAtIndex:0];
                payment = [SKPayment paymentWithProduct:product];
                [[SKPaymentQueue defaultQueue] addPayment:payment];
            }
        }
        else //retry
        {
            addQueueRetries++;
            [self requestProductData];
            [self performSelector:@selector(addToQueue:) withObject:productId afterDelay:addQueueRetries*2];
        }
	}
	else
	{
        [self showAlertWithTitle:NSLocalizedString(@"In-App Purchasing disabled", @"")
                         message:NSLocalizedString(@"Check your parental control settings and / or your internet connection and try again.", @"")];
        addQueueRetries = 0;
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        self.onTransactionCancelled();
	}
}

- (BOOL) canConsumeProduct:(NSString*) productIdentifier
{
	int count = [[MKStoreManager numberForKey:productIdentifier] intValue];

	return (count > 0);

}

- (BOOL) canConsumeProduct:(NSString*) productIdentifier quantity:(int) quantity
{
	int count = [[MKStoreManager numberForKey:productIdentifier] intValue];
	return (count >= quantity);
}

- (BOOL) consumeProduct:(NSString*) productIdentifier quantity:(int) quantity
{
	int count = [[MKStoreManager numberForKey:productIdentifier] intValue];
	if(count < quantity)
	{
		return NO;
	}
	else
	{
		count -= quantity;
        [MKStoreManager setObject:[NSNumber numberWithInt:count] forKey:productIdentifier];
		return YES;
	}
}

- (void) startVerifyingSubscriptionReceipts
{
    NSDictionary *subscriptions = [[self storeKitItems] objectForKey:@"Subscriptions"];

    self.subscriptionProducts = [NSMutableDictionary dictionary];
    for(NSString *productId in [subscriptions allKeys])
    {
        MKSKSubscriptionProduct *product = [[[MKSKSubscriptionProduct alloc] initWithProductId:productId subscriptionDays:[[subscriptions objectForKey:productId] intValue]] autorelease];
        product.receipt = [MKStoreManager dataForKey:productId]; // cached receipt

        if(product.receipt)
        {
            [product verifyReceiptOnComplete:^(NSNumber* isActive)
             {
                 if([isActive boolValue] == NO)
                 {
                     [[NSNotificationCenter defaultCenter] postNotificationName:kSubscriptionsInvalidNotification
                                                                         object:product.productId];

                     NSLog(@"Subscription: %@ is inactive", product.productId);
                 }
                 else
                 {
                     NSLog(@"Subscription: %@ is active", product.productId);
                 }
             }
                                     onError:^(NSError* error)
             {
                 NSLog(@"Unable to check for subscription validity right now");
             }];
        }

        [self.subscriptionProducts setObject:product forKey:productId];
    }
}

-(NSData*) receiptFromBundle {

    return nil;
}

#pragma mark In-App purchases callbacks
// In most cases you don't have to touch these methods
-(void) provideContent: (NSString*) productIdentifier
            forReceipt:(NSData*) receiptData
{
    MKSKSubscriptionProduct *subscriptionProduct = [self.subscriptionProducts objectForKey:productIdentifier];
    if(subscriptionProduct)
    {
        // MAC In App Purchases can never be a subscription product (at least as on Dec 2011)
        // so this can be safely ignored.

        subscriptionProduct.receipt = receiptData;
        [subscriptionProduct verifyReceiptOnComplete:^(NSNumber* isActive)
         {
             [[NSNotificationCenter defaultCenter] postNotificationName:kSubscriptionsPurchasedNotification
                                                                 object:productIdentifier];

             [MKStoreManager setObject:receiptData forKey:productIdentifier];
         }
                                             onError:^(NSError* error)
         {
             NSLog(@"%@", [error description]);
         }];
    }
    else
    {
        if(!receiptData) {

            // could be a mac in app receipt.
            // read from receipts and verify here
            receiptData = [self receiptFromBundle];
            if(!receiptData) {
                if(self.onTransactionCancelled)
                {
                    self.onTransactionCancelled(productIdentifier);
                }
                else
                {
                    NSLog(@"Receipt invalid");
                }
            }
        }

        if(OWN_SERVER && SERVER_PRODUCT_MODEL)
        {
            // ping server and get response before serializing the product
            // this is a blocking call to post receipt data to your server
            // it should normally take a couple of seconds on a good 3G connection
            MKSKProduct *thisProduct = [[[MKSKProduct alloc] initWithProductId:productIdentifier receiptData:receiptData] autorelease];

            [thisProduct verifyReceiptOnComplete:^
             {
                 [self rememberPurchaseOfProduct:productIdentifier withReceipt:receiptData];
             }
                                         onError:^(NSError* error)
             {
                 if(self.onTransactionCancelled)
                 {
                     self.onTransactionCancelled(productIdentifier);
                 }
                 else
                 {
                     NSLog(@"The receipt could not be verified");
                 }
             }];
        }
        else
        {
            [self rememberPurchaseOfProduct:productIdentifier withReceipt:receiptData];
            if(self.onTransactionCompleted)
                self.onTransactionCompleted(productIdentifier, receiptData);
        }
    }
}

-(void) rememberPurchaseOfProduct:(NSString*) productIdentifier withReceipt:(NSData*) receiptData
{
    NSDictionary *allConsumables = [[self storeKitItems] objectForKey:@"Consumables"];
    if([[allConsumables allKeys] containsObject:productIdentifier])
    {
        NSDictionary *thisConsumableDict = [allConsumables objectForKey:productIdentifier];
        int quantityPurchased = [[thisConsumableDict objectForKey:@"Count"] intValue];
        NSString* productPurchased = [thisConsumableDict objectForKey:@"Name"];

        int oldCount = [[MKStoreManager numberForKey:productPurchased] intValue];
        int newCount = oldCount + quantityPurchased;

        [MKStoreManager setObject:[NSNumber numberWithInt:newCount] forKey:productPurchased];
    }
    else
    {
        [MKStoreManager setObject:[NSNumber numberWithBool:YES] forKey:productIdentifier];
    }
    if (receiptData && [receiptData length])
    {
        [MKStoreManager setObject:receiptData forKey:[NSString stringWithFormat:@"%@-receipt", productIdentifier]];
    }
}

- (void) transactionCanceled: (SKPaymentTransaction *)transaction
{

#ifndef NDEBUG
	NSLog(@"User cancelled transaction: %@", [transaction description]);
    NSLog(@"error: %@", transaction.error);
#endif

    if(self.onTransactionCancelled)
        self.onTransactionCancelled();
}

- (void) failedTransaction: (SKPaymentTransaction *)transaction
{
#ifndef NDEBUG
    NSLog(@"Failed transaction: %@", [transaction description]);
    NSLog(@"error: %@", transaction.error);
#endif
    [self showAlertWithTitle:@"In-App Purchase Transaction Failed"  message:[transaction.error localizedDescription]];
    if(self.onTransactionCancelled)
        self.onTransactionCancelled();
}

@synthesize purchasableObjects = _purchasableObjects;
@synthesize storeObserver = _storeObserver;
@synthesize currentRequest = _currentRequest;
@synthesize reachability = _reachability;
@synthesize subscriptionProducts;
@synthesize productsAvailable = _productsAvailable;
@synthesize onTransactionCancelled;
@synthesize onTransactionCompleted;
@synthesize onRestoreFailed;
@synthesize onRestoreCompleted;

- (void)dealloc
{
    [self.reachability stopNotifier];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
    [_reachability release], _reachability = nil;
    [_purchasableObjects release], _purchasableObjects = nil;
    [_storeObserver release], _storeObserver = nil;
    [onTransactionCancelled release], onTransactionCancelled = nil;
    [onTransactionCompleted release], onTransactionCompleted = nil;
    [onRestoreFailed release], onRestoreFailed = nil;
    [onRestoreCompleted release], onRestoreCompleted = nil;
    [super dealloc];
}

+ (void) dealloc
{
	[_sharedStoreManager release], _sharedStoreManager = nil;
	[super dealloc];
}

@end

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

@interface MKStoreManager () //private methods and properties

@property (nonatomic, copy) void (^onTransactionCancelled)(NSError *error);
@property (nonatomic, copy) void (^onTransactionCompleted)(NSString *productId);

@property (nonatomic, copy) void (^onRestoreFailed)(NSError* error);
@property (nonatomic, copy) void (^onRestoreCompleted)();

@property (nonatomic, strong) NSMutableArray *purchasableObjects;
@property (nonatomic, strong) NSMutableDictionary *subscriptionProducts;
@property (nonatomic, strong) Reachability *reachability;
@property (nonatomic, retain) MKStoreObserver *storeObserver;
@property (nonatomic, retain) SKProductsRequest *currentRequest;
@property (nonatomic, assign, getter=areProductsAvailable) BOOL productsAvailable;

- (void) requestProductData;
- (void) startVerifyingSubscriptionReceipts;
-(void) rememberPurchaseOfProduct:(NSString*) productIdentifier;
-(void) addToQueue:(NSString*) productId;
@end

@implementation MKStoreManager

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

static MKStoreManager* _sharedStoreManager;

-(BOOL)fetchingProducts
{
    return [self currentRequest] != nil;
}

-(void) updateFromiCloud:(NSNotification*) notificationObject {
    NSUbiquitousKeyValueStore *iCloudStore = [NSUbiquitousKeyValueStore defaultStore];
    NSDictionary *dict = [iCloudStore dictionaryRepresentation];
    
    __block NSArray *consumables = [[[self storeKitItems] objectForKey:@"Consumables"] allKeys];
    __block NSArray *nonConsumables = [[self storeKitItems] objectForKey:@"Non-Consumables"];
    __block NSArray *subscriptions = [[[self storeKitItems] objectForKey:@"Subscriptions"] allKeys];
    
    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        BOOL isItem = NO;
        
        isItem|= [consumables containsObject:key];
        isItem|= [nonConsumables containsObject:key];
        isItem|= [subscriptions containsObject:key];
        
        if (isItem)
        {
            [[self class] setObject:obj forKey:key];
        }
    }];    
}

+(BOOL) iCloudAvailable {
    return NO;
    /*
     if(NSClassFromString(@"NSUbiquitousKeyValueStore")) { // is iOS 5?
     
     if([NSUbiquitousKeyValueStore defaultStore]) {  // is iCloud enabled
     
     return YES;
     }
     }
     
     return NO;
     */
}

- (void)dealloc 
{
    [self.reachability stopNotifier];  
}

+ (void) dealloc
{
	_sharedStoreManager = nil;
	[super dealloc];
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
        objectString = [[NSString alloc] initWithData:object encoding:NSUTF8StringEncoding];
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
        _sharedStoreManager.storeObserver = [[MKStoreObserver alloc] init];
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

+ (id)allocWithZone:(NSZone *)zone
{	
    return [self sharedManager];
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

#pragma mark Internal MKStoreKit functions

-(NSDictionary*) storeKitItems
{
	static NSDictionary *skItems;
	if (!skItems)
	{
		skItems = [NSDictionary dictionaryWithContentsOfFile:
				   [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
					@"MKStoreKitConfigs.plist"]];
	}
    return skItems;
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

-(void) requestProductData
{
    if (![self currentRequest])
    {
        
        NSMutableArray *productsArray = [NSMutableArray array];
        NSArray *consumables = [[[self storeKitItems] objectForKey:@"Consumables"] allKeys];
        NSArray *nonConsumables = [[self storeKitItems] objectForKey:@"Non-Consumables"];
        NSArray *subscriptions = [[[self storeKitItems] objectForKey:@"Subscriptions"] allKeys];
        
        [productsArray addObjectsFromArray:consumables];
        [productsArray addObjectsFromArray:nonConsumables];
        [productsArray addObjectsFromArray:subscriptions];
        
        SKProductsRequest *request= [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithArray:productsArray]];
        request.delegate = self;
        [self setCurrentRequest:request];
        
        [request start];
    }
}

- (BOOL) removeAllKeychainData {
    NSMutableArray *productsArray = [NSMutableArray array];
    NSArray *consumables = [[[self storeKitItems] objectForKey:@"Consumables"] allKeys];
    NSArray *nonConsumables = [[self storeKitItems] objectForKey:@"Non-Consumables"];
    NSArray *subscriptions = [[[self storeKitItems] objectForKey:@"Subscriptions"] allKeys];
    
    [productsArray addObjectsFromArray:consumables];
    [productsArray addObjectsFromArray:nonConsumables];
    [productsArray addObjectsFromArray:subscriptions];
    
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
	[self setProductsAvailable:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:kProductFetchedNotification 
                                                        object:[NSNumber numberWithBool:self.productsAvailable]];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error
{
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
		
		// you might probably need to change this line to suit your UI needs
		NSString *description = [NSString stringWithFormat:@"%@ (%@)",[product localizedTitle], formattedString];
		
#ifndef NDEBUG
		NSLog(@"Product %d - %@", i, description);
#endif
		[productDescriptions addObject: description];
	}
	
	return [NSArray arrayWithArray:productDescriptions];
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
         onComplete:(void (^)(NSString*)) completionBlock         
        onCancelled:(void (^)(NSError*)) cancelBlock
{
    self.onTransactionCompleted = completionBlock;
    self.onTransactionCancelled = cancelBlock;
    
    [MKSKProduct verifyProductForReviewAccess:featureId                                                              
                                   onComplete:^(NSNumber * isAllowed)
     {
         if([isAllowed boolValue])
         {
             [self showAlertWithTitle:NSLocalizedString(@"Review request approved", @"")
                              message:NSLocalizedString(@"You can use this feature for reviewing the app.", @"")];
             
             if(self.onTransactionCompleted)
                 self.onTransactionCompleted(featureId);                                         
         }
         else
         {
             [self addToQueue:featureId];
         }
     }                                                                   
                                      onError:^(NSError* error)
     {
         NSLog(@"Review request cannot be checked now: %@", [error description]);
         [self addToQueue:featureId];
     }];    
}

-(void) addToQueue:(NSString*) productId
{
    if ([SKPaymentQueue canMakePayments])
	{
        NSArray *allIds = [self.purchasableObjects valueForKey:@"productIdentifier"];
        int index = [allIds indexOfObject:productId];
        
        if(index == NSNotFound) return;
        
        SKProduct *thisProduct = [self.purchasableObjects objectAtIndex:index];
		SKPayment *payment = [SKPayment paymentWithProduct:thisProduct];
		[[SKPaymentQueue defaultQueue] addPayment:payment];
	}
	else
	{
        [self showAlertWithTitle:NSLocalizedString(@"In-App Purchasing disabled", @"")
                         message:NSLocalizedString(@"Check your parental control settings and try again later", @"")];
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
        MKSKSubscriptionProduct *product = [[MKSKSubscriptionProduct alloc] initWithProductId:productId subscriptionDays:[[subscriptions objectForKey:productId] intValue]];        
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
                    NSString *description = [NSString stringWithFormat:@"Receipt invalid for product %@", productIdentifier];
                    NSDictionary *uInfo = [NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
                    NSError *err = [NSError errorWithDomain:@"com.company.product.malformedPDFDATA" code:0 userInfo:uInfo];
                    self.onTransactionCancelled(err);
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
            MKSKProduct *thisProduct = [[MKSKProduct alloc] initWithProductId:productIdentifier receiptData:receiptData];
            
            [thisProduct verifyReceiptOnComplete:^
             {
                 [self rememberPurchaseOfProduct:productIdentifier];
                 if(self.onTransactionCompleted)
                     self.onTransactionCompleted(productIdentifier);
             }
                                         onError:^(NSError* error)
             {
                 if(self.onTransactionCancelled)
                 {
                     self.onTransactionCancelled(error);
                 }
                 else
                 {
                     NSLog(@"The receipt could not be verified");
                 }
             }];            
        }
        else
        {
            [self rememberPurchaseOfProduct:productIdentifier];
            if(self.onTransactionCompleted)
                self.onTransactionCompleted(productIdentifier);
        }                
    }
}


-(void) rememberPurchaseOfProduct:(NSString*) productIdentifier
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
}

- (void) transactionCanceled: (SKPaymentTransaction *)transaction
{
    
#ifndef NDEBUG
	NSLog(@"User cancelled transaction: %@", [transaction description]);
    NSLog(@"error: %@", transaction.error);
#endif
    
    if(self.onTransactionCancelled)
        self.onTransactionCancelled(transaction.error);
}

- (void) failedTransaction: (SKPaymentTransaction *)transaction
{
#ifndef NDEBUG
    NSLog(@"Failed transaction: %@", [transaction description]);
    NSLog(@"error: %@", transaction.error);    
#endif
    [self showAlertWithTitle:@"In-App Purchase Transaction Failed"  message:[transaction.error localizedDescription]];
    if(self.onTransactionCancelled)
        self.onTransactionCancelled(transaction.error);
}

@end

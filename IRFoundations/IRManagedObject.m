//
//  IRManagedObject.m
//  Milk
//
//  Created by Evadne Wu on 1/11/11.
//  Copyright 2011 Iridia Productions. All rights reserved.
//

#import "IRManagedObject.h"


@implementation IRManagedObject

+ (NSArray *) insertOrUpdateObjectsIntoContext:(NSManagedObjectContext *)context withExistingProperty:(NSString *)managedObjectKeyPath matchingKeyPath:(NSString *)dictionaryKeyPath ofRemoteDictionaries:(NSArray *)dictionaries {

//	The value that local or remote key paths point to will be called markers

	if (!dictionaries || [dictionaries isEqual:[NSNull null]] || ([dictionaries count] == 0))
	return nil;
	
	if (!managedObjectKeyPath || !dictionaryKeyPath)
	return nil;
	
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	NSError *error = nil;
	NSArray *existingEntities = [context executeFetchRequest:(( ^ {

		NSFetchRequest *returnedRequest = [[[NSFetchRequest alloc] init] autorelease];

		[returnedRequest setEntity:[NSEntityDescription entityForName:[self coreDataEntityName] inManagedObjectContext:context]];
		
		[returnedRequest setPredicate:[NSPredicate predicateWithFormat:
		
			@"(%K IN %@)", 
		
			managedObjectKeyPath, 
			[[dictionaries irMap:irMapMakeWithKeyPath(dictionaryKeyPath)] irMap:irMapNullFilterMake()]
			
		]];
		
		[returnedRequest setSortDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:managedObjectKeyPath ascending:YES]]];
		
		[returnedRequest setReturnsObjectsAsFaults:NO];
		
		return returnedRequest;
	
	})()) error:&error];
	
	if (!existingEntities)
	return nil;
	
	
	IRMOLog(@"%s fetching existing entities %@", __PRETTY_FUNCTION__, existingEntities);
	
	NSUInteger existingEntitiesCount = [existingEntities count];
	__block NSUInteger currentEntityIndex = -1;
	IRManagedObject *currentEntity = (existingEntitiesCount > 0) ? [existingEntities objectAtIndex:0] : nil;

	id (^nextEntity)() = ^ {
	
		if (!currentEntity)
		return (id)nil;

		currentEntityIndex++;
		
		if (currentEntityIndex == existingEntitiesCount)
		return (id)nil;
		
		return (id)[existingEntities objectAtIndex:currentEntityIndex];
		
	};


	NSComparisonResult (^compare) (id, id) = ^ (id inEntity, id inRemoteDictionary) {
	
		return [[inEntity valueForKey:managedObjectKeyPath] compare:[inRemoteDictionary valueForKeyPath:dictionaryKeyPath]];
	
	};
	
	NSMutableArray *returnedEntities = [[dictionaries mutableCopy] autorelease];
	NSArray *sortedRemoteDictionaries = [dictionaries sortedArrayUsingComparator:irComparatorMakeWithNodeKeyPath(dictionaryKeyPath)];
	
	
	NSMutableArray *updatedOrInsertedReps = [NSMutableArray array];
	
	
//	The remote dictionaries are sorted by the value at a particular key path.  There may be duplicates.
//	Duplicates get wrapped into an array containing every representation.

	__block NSMutableArray *currentWrapperArray = nil;
	
	NSArray *uniqueValues = [[sortedRemoteDictionaries irMap:^(id inObject, int index, BOOL *stop) {
	
		return [inObject valueForKeyPath:dictionaryKeyPath];
	
	}] irMap:irMapNullFilterMake()];
	
	[uniqueValues enumerateObjectsUsingBlock: ^ (id currentUniqueValue, NSUInteger idx, BOOL *stop) {
	
		id currentObject = [sortedRemoteDictionaries objectAtIndex:idx];
	
		if (idx > 0)
		if ([currentUniqueValue isEqual:[uniqueValues objectAtIndex:(idx - 1)]]) {

			[currentWrapperArray addObject:currentObject];
			return;
		
		}
	
		NSMutableArray *wrapperArray = [NSMutableArray array];
		[updatedOrInsertedReps addObject:wrapperArray];
		[wrapperArray addObject:currentObject];
		
		currentWrapperArray = wrapperArray;
	
	}];
	
	
	//	There is a circumstance, where the multiple remote dictionaries can have a same value at dictionaryKeyPath
	
	for (NSArray *currentDictionaryWrapper in updatedOrInsertedReps) {
	
		id currentDictionary = [currentDictionaryWrapper objectAtIndex:0];
	
		if ([currentDictionary isEqual:[NSNull null]])
		continue;
		
	//	When the dictionary has a marker that is ahead of the entity, move on to the next entity
		
		if (currentEntity)
		while (compare(currentEntity, currentDictionary) == NSOrderedAscending) {
		
			currentEntity = nextEntity();
			
			if (!currentEntity)
			break;
					
		}
		
		
	//	The marker of the dictionary is guaranteed to match, or fall behind the current entity
	
		IRManagedObject *touchedEntity = nil;
		
		
		NSDictionary *configurationDictionary = (( ^ {
		
			if ([currentDictionaryWrapper count] == 1)
			return currentDictionary;
		
			NSMutableDictionary *returnedDictionary = [currentDictionary mutableCopy];
			
			[currentDictionaryWrapper enumerateObjectsUsingBlock: ^ (NSDictionary *aDictionary, NSUInteger idx, BOOL *stop) {
	
				[returnedDictionary addEntriesFromDictionary:aDictionary];
	
			}];
			
			return returnedDictionary;
		
		})());
		
		
	//	Compare only the master key path.  Since only the master is compared there is only need to make sure we touch the entity only ONCE per loop, hence the composited dictionary is used to avoid potentially very costly object configuration.
		
		if ((currentEntity != nil) && (compare(currentEntity, currentDictionary) == NSOrderedSame)) {
		
			touchedEntity = currentEntity;
			[touchedEntity configureWithRemoteDictionary:configurationDictionary];
		
		} else {
		
			touchedEntity = [self objectInsertingIntoContext:context withRemoteDictionary:configurationDictionary];
		
		}
		
		
	//	If there are multiple representations, use them up
		
		[[returnedEntities indexesOfObjectsPassingTest: ^ (id obj, NSUInteger idx, BOOL *stop) {
		
			if (![obj isKindOfClass:[NSDictionary class]])
			return NO;
		
			return [[obj valueForKeyPath:dictionaryKeyPath] isEqual:[currentDictionary valueForKeyPath:dictionaryKeyPath]];
		
		//	This will NOT work with eventually-consistent-style systems
		//	For example, Twitter itself can change its mind about an user’s following count in the middle of a response body!
		//	return [obj isEqual:currentDictionary];
		
		}] enumerateIndexesUsingBlock: ^ (NSUInteger idx, BOOL *stop) {

			[returnedEntities replaceObjectAtIndex:idx withObject:touchedEntity];
		
		}];
		
	}
	
	[returnedEntities retain];
	[pool drain];

#if 0	
#ifdef DEBUG

	for (id anObject in returnedEntities)
	if (!([anObject isKindOfClass:[NSManagedObject class]] || [anObject isEqual:[NSNull null]]))
	NSAssert(NO, @"Something missed our eyes.");

#endif
#endif
	
	return [returnedEntities autorelease];

}





+ (NSArray *) insertOrUpdateObjectsUsingContext:(NSManagedObjectContext *)context withRemoteResponse:(NSArray *)inRemoteDictionaries usingMapping:(NSDictionary *)remoteKeyPathsToClassNames options:(int)options {

	if (!inRemoteDictionaries)
	return [NSArray array];
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	[[context retain] autorelease];
	[[inRemoteDictionaries retain] autorelease];
	[[remoteKeyPathsToClassNames retain] autorelease];

	NSString *localKeyPath = [self keyPathHoldingUniqueValue];
	NSString *remoteKeyPath = [[[self remoteDictionaryConfigurationMapping] allKeysForObject:localKeyPath] objectAtIndex:0];
	
	NSArray *baseEntities = [self insertOrUpdateObjectsIntoContext:context withExistingProperty:localKeyPath matchingKeyPath:remoteKeyPath ofRemoteDictionaries:inRemoteDictionaries];
	
	NSDictionary *baseEntityRelationships = [[[[[context persistentStoreCoordinator] managedObjectModel] entitiesByName] objectForKey:[self coreDataEntityName]] relationshipsByName];
	
	
	for (NSString *rootRemoteKeyPath in remoteKeyPathsToClassNames) {
	
		Class nodeEntityClass = NSClassFromString([remoteKeyPathsToClassNames objectForKey:rootRemoteKeyPath]);

		NSString *rootLocalKeyPath = [[self remoteDictionaryConfigurationMapping] objectForKey:rootRemoteKeyPath];
	
	//	Skip if the local key path is not mappable
		if (!rootLocalKeyPath) {
		
			[NSException raise:NSInternalInconsistencyException format:@"A remote mapping %@ -> %@ is not found, using mapping %@", rootRemoteKeyPath, NSStringFromClass(nodeEntityClass), [self remoteDictionaryConfigurationMapping]];
			
			continue;
			
		}
		
		NSString *nodeLocalKeyPath = [nodeEntityClass keyPathHoldingUniqueValue];
		NSString *nodeRemoteKeyPath = [[[nodeEntityClass remoteDictionaryConfigurationMapping] allKeysForObject:nodeLocalKeyPath] objectAtIndex:0];
		
		NSArray *nodeRepresentations = [inRemoteDictionaries irMap:irMapMakeWithKeyPath(rootRemoteKeyPath)];
		NSArray *entityRepresentations = [nodeRepresentations irFlatten];
		
		NSArray *nodeEntities = [nodeEntityClass insertOrUpdateObjectsIntoContext:context withExistingProperty:nodeLocalKeyPath matchingKeyPath:nodeRemoteKeyPath ofRemoteDictionaries:entityRepresentations];
		
		BOOL relationIsToMany = [[baseEntityRelationships objectForKey:rootLocalKeyPath] isToMany];
		
		
		__block NSUInteger consumedNodeEntities = 0;
		
		[baseEntities enumerateObjectsUsingBlock: ^ (IRManagedObject *baseObject, NSUInteger index, BOOL *stop) {
		
			NSUInteger relatedNodesCount = irCount([nodeRepresentations objectAtIndex:index], 0);
			
			if (relatedNodesCount == 0)
			return;
			
			NSAssert(!([rootLocalKeyPath isEqual:[NSNull null]] || !rootLocalKeyPath), @"local key path for remote key path %@ can’t be null or nil.", rootRemoteKeyPath);
			
			NSArray *relatedEntities = [nodeEntities subarrayWithRange:NSMakeRange(consumedNodeEntities, relatedNodesCount)];
			
			if (relationIsToMany) {
			
				[[baseObject mutableSetValueForKeyPath:rootLocalKeyPath] addObjectsFromArray:relatedEntities];
			
			} else {
			
				[baseObject setValue:[relatedEntities objectAtIndex:0] forKeyPath:rootLocalKeyPath];
			
			}
			
			consumedNodeEntities += relatedNodesCount;
			
#if 0 && defined(DEBUG)

		//	If you pass multiple representations of an identical object, you will surely get a lot of identical objects (same pointer!) so we will use a NSSet to check it out.

			if (!(relationIsToMany || (!relationIsToMany && (relatedNodesCount == 1))))
			if ([[NSSet setWithArray:nodeEntities] count] != 1) {
			
				NSAssert(NO, @"A to-one relationship has multiple related entities.");
				
			}
			
#endif
		
		}];
		
		
		if (consumedNodeEntities != [nodeEntities count])
		[NSException raise:NSInternalInconsistencyException format:@"%s expects to exhaust all entities.", __PRETTY_FUNCTION__];
		
	}
	
	[baseEntities retain];
	[pool drain];
	
	return [baseEntities autorelease];

}





+ (NSString *) keyPathHoldingUniqueValue {

	return nil;

}





+ (NSString *) coreDataEntityName {

	return NSStringFromClass([self class]);

}

+ (id) objectInsertingIntoContext:(NSManagedObjectContext *)inContext withRemoteDictionary:(NSDictionary *)inDictionary {

	IRManagedObject *returnedStatus = nil;

	@try {

		returnedStatus = [[[self alloc] initWithEntity:[NSEntityDescription entityForName:[self coreDataEntityName] inManagedObjectContext:inContext] insertIntoManagedObjectContext:inContext] autorelease];
		
	} @catch (NSException *e) {
	
		NSLog(@"Exception: %@", e);
	
	}
	
	if (!returnedStatus)
	return nil;
	
	[returnedStatus configureWithRemoteDictionary:inDictionary];
	
	return returnedStatus;

}

@end





@interface IRManagedObject (WebAPIImporting_Private)

+ (BOOL) skipsNonexistantRemoteKey;
+ (BOOL) skipsNullValue;

@end

@implementation IRManagedObject (WebAPIImporting_Private)

+ (BOOL) skipsNonexistantRemoteKey {

	return [[self placeholderForNonexistantKey] isEqual:[IRNoOp noOp]];

}

+ (BOOL) skipsNullValue {

	return [[self placeholderForNullValue] isEqual:[IRNoOp noOp]];	

}

@end

@implementation IRManagedObject (WebAPIImporting)

+ (NSDictionary *) remoteDictionaryConfigurationMapping {

	return nil;

}

+ (id) transformedValue:(id)aValue fromRemoteKeyPath:(NSString *)aRemoteKeyPath toLocalKeyPath:(NSString *)aLocalKeyPath {

	return aValue;

}

+ (id<NSObject>) placeholderForNonexistantKey {

	return nil;

}

+ (id<NSObject>) placeholderForNullValue {

	return nil;

}

- (void) configureWithRemoteDictionary:(NSDictionary *)inDictionary {

	NSDictionary *configurationMapping = [[self class] remoteDictionaryConfigurationMapping];

	if (!configurationMapping)
	return;
	
	NSAssert([configurationMapping isKindOfClass:[NSDictionary class]], @"-configureWithDictionary found +remoteDictionaryConfigurationMapping, unfortunately -isKindOfClass: disagrees with its type.");
	
	BOOL skipsNonexistantRemoteKey = [[self class] skipsNonexistantRemoteKey];
	id nonexistantRemoteKeyPlaceholder = [[self class] placeholderForNonexistantKey];
	
	BOOL skipsNullValue = [[self class] skipsNullValue];
	id nullValuePlaceholder = [[self class] placeholderForNullValue];
	
	for (id aRemoteKeyPath in configurationMapping) {
	
		id aRemoteValueOrNil = [inDictionary valueForKeyPath:aRemoteKeyPath];
	
	//	A remote dictionary at the end means that it is a composite representation, not to be assigned as a property value
		if ([aRemoteValueOrNil isKindOfClass:[NSDictionary class]])
		continue;
		
		id aLocalKeyPathOrNSNull = [configurationMapping objectForKey:aRemoteKeyPath];
		
		if ([aLocalKeyPathOrNSNull isEqual:[NSNull null]])
		continue;
		
		NSAssert([aLocalKeyPathOrNSNull isKindOfClass:[NSString class]], @"in +remoteDictionaryConfigurationMapping, the local key path must be a NSString, or [NSNull null].");
		NSString *aLocalKeyPath = (NSString *)aLocalKeyPathOrNSNull;
		
		id committedValue = aRemoteValueOrNil;
		
		if (!aRemoteValueOrNil) {
		
			if (skipsNonexistantRemoteKey)
			continue;
			
			committedValue = nonexistantRemoteKeyPlaceholder;
		
		} else if ([aRemoteValueOrNil isEqual:[NSNull null]]) {
		
			if (skipsNullValue)
			continue;
			
			committedValue = nullValuePlaceholder;
		
		}
		
	//	If the committed value is actually an array we assume that it’ll be taken care of by insertOrUpdateObjectsUsingContext:withRemoteResponse:usingMapping:options: instead
		
		if (![committedValue isKindOfClass:[NSArray class]])
		[self setValue:[[self class] transformedValue:committedValue fromRemoteKeyPath:aRemoteKeyPath toLocalKeyPath:aLocalKeyPath] forKeyPath:aLocalKeyPath];
			
	}
	
}

@end





@implementation IRManagedObject (DelayedPerforming)

- (void) performSafely:(void(^)(void))aBlock {

	[self performSafely:aBlock withExceptionHandler: ^ (NSException *e) {
	
		NSLog(@"Core Data Exception: %@", e);
	
		if ([e isEqual:NSObjectInaccessibleException])
		return YES;
		
		if ([e isEqual:NSObjectNotAvailableException])
		return YES;
		
		return NO;
	
	}];

}

- (void) performSafely:(void(^)(void))aBlock withExceptionHandler:(BOOL(^)(NSException *e))exceptionHandlerOrNil {

	dispatch_async(dispatch_get_current_queue(), ^ {
	
		@try {
		
			aBlock();
		
		} @catch (NSException * e) {
			
			if (!exceptionHandlerOrNil || (exceptionHandlerOrNil && !exceptionHandlerOrNil(e)))
			@throw e;
		
		}
	
	});

}

@end


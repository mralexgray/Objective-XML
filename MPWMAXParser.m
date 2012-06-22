//
//  MPWMAXParser.m
//  MPWXmlKit
//
//  Created by Marcel Weiher on 8/4/07.
//  Copyright 2007 . All rights reserved.
//

#import "MPWMAXParser.h"
#import "MPWXmlAttributes.h"
#import "MPWTagHandler.h"
#import "mpwfoundation_imports.h"
#import "MPWXmlScanner.h"
#import "MPWMAXParser_private.h"
#import "SaxDocumentHandler.h"
#import "MPWXmlElement.h"


#if TARGET_OS_IPHONE
#define CFMakeCollectable(x)   (x)
#endif


static void doNothing() { }
static BOOL returnYes() { return YES; }
static BOOL returnNo() { return NO; }

NSString *MPWXMLCDataKey=@"MPWXMLCDataKey";
NSString *MPWXMLPCDataKey=@"MPWXMLPCDataKey";


@implementation MPWMAXParser

intAccessor( undefinedTagAction, setUndefinedTagAction)
intAccessor( cfDataEncoding, setCfDataEncoding )
intAccessor( dataEncoding, _setDataEncoding )
idAccessor( defaultNamespaceHandler, setDefaultNamespaceHandler	)
boolAccessor( reportIgnoreableWhitespace, setReportIgnoreableWhitespace )
boolAccessor( ignoreCase, setIgnoreCase )
scalarAccessor( NSInteger, maxDepthAllowed, setMaxDepthAllowed )
objectAccessor( NSData, buffer, setBuffer )
objectAccessor( NSURL, url, setUrl )

#define MAKEDATA( start, length )   initDataBytesLength( getData( dataCache, @selector(getObject)),@selector(reInitWithData:bytes:length:), data, start , length )

#define POPTAG						( [((NSXMLElementInfo*)_elementStack)[--tagStackLen].elementName release])
#define PUSHTAG(aTag) {\
    if ( tagStackLen > tagStackCapacity ) {\
        [self _growTagStack:(tagStackCapacity+2) * 2];\
    }\
    ((NSXMLElementInfo*)_elementStack)[tagStackLen++].elementName=[aTag retain];\
}
#define TAGFORCSTRING( cstr, len )  uniqueTagForCString(self, @selector(getTagForCString:length:) , cstr, len )

#define	INITIALOBJECTSTACKDEPTH 100

//static Class uniqueStringClass=nil;
//static Class SubDataClass = nil;
//static Class XmlAttributeClass =nil;

idAccessor( parseResult, setParseResult )
idAccessor( version, setVersion )
idAccessor( scanner, setScanner )
idAccessor( data, setData )
scalarAccessor( id  ,documentHandler, _setDocumentHandler)
idAccessor( _attributes, _setAttributes)
boolAccessor( shouldProcessNamespaces, setShouldProcessNamespaces )
boolAccessor( shouldReportNamespacePrefixes, setShouldReportNamespacePrefixes )
boolAccessor( autotranslateUTF8, setAutotranslateUTF8 )
boolAccessor( enforceTagNesting, setEnforceTagNesting )
objectAccessor( NSError, parserError, setParserError  )


static inline BOOL extractNameSpace( const char *start, int len, const char **strippedTagPtr, int *namespaceLen, int *tagLen )
{
	char *namespacePtr=memchr(start, ':', len);
	if ( namespacePtr ) {
		*namespaceLen=namespacePtr-start;
		*tagLen=len-*namespaceLen-1;
		*strippedTagPtr=start+*namespaceLen+1;
		return YES;
	} else {
		*strippedTagPtr=start;
		*tagLen=len;
		*namespaceLen=0;
		return NO;
	}
}




-(void)setDataEncoding:(int)newEncoding
{
	[self _setDataEncoding:newEncoding];
#ifndef WINDOWS	
	[self setCfDataEncoding: CFStringConvertNSStringEncodingToEncoding( newEncoding )];
#endif	
}

-init
{
//     id pool=[[NSAutoreleasePool alloc] init];
   self = [super init];
//	NSLog(@"init");
    @autoreleasepool {
        [self setScanner:[[[NSXMLScanner alloc] init] autorelease]];
    }

    @autoreleasepool {

//	NSLog(@"scanner");
	[[self scanner] setDelegate:self];
	
 //	NSLog(@"before dataCache");
   dataCache=[[MPWObjectCache alloc] initWithCapacity:90 class:[MPWSubData class]];
    [dataCache setUnsafeFastAlloc:YES];
    getData = [dataCache getObjectIMP];
    initDataBytesLength=[MPWSubData
                    instanceMethodForSelector:@selector(reInitWithData:bytes:length:)];
	uniqueTagForCString=[self methodForSelector: @selector(getTagForCString:length:)];
    [self _growTagStack:INITIALTAGSTACKDEPTH];
//	NSLog(@"before attributeCache");
    attributeCache=[[MPWObjectCache alloc] initWithCapacity:20 class:[MPWXMLAttributes class]];
    [attributeCache setUnsafeFastAlloc:YES];
	[self setDelegate:self];
    ignoreSpace=YES;
	[self setEnforceTagNesting:YES];
	[self setDataEncoding:NSUTF8StringEncoding];
	[self setUndefinedTagAction:MAX_ACTION_PLIST];
	tagStackLen=0;
//	NSLog(@"before setDefaultNamespaceHandler");
	[self setDefaultNamespaceHandler:nil];
//  if ( !XmlAttributeClass ) {
//        XmlAttributeClass=[MPWXMLAttributes class];
 //       uniqueStringClass=[MPWUniqueString class];
//        SubDataClass = [MPWSubData class];
//    }
    [self setDelegate:self];
	[self setReportIgnoreableWhitespace:NO];
	namespaceHandlers=[[NSMutableDictionary alloc] init];
	namespacePrefixToURIMap=[[NSMutableDictionary alloc] init];
	maxDepthAllowed=INT_MAX;
//	NSLog(@"before setHandler");
	[self setHandler:self forElements:[NSArray array] inNamespace:nil prefix:@"" map:nil ];
//	NSLog(@"after setHandler");
//	[pool release];
	autotranslateUTF8=YES;
    }
	return self;
}



-initWithData:(NSData*)newXmlData
{
	self=[self init];
	[self setData:newXmlData];
	[self setAutotranslateUTF8:YES];
	return self;
}

-initWithContentsOfURL:(NSURL*)newURL
{
	self=[self init];
	[self setUrl:newURL];
	[self setAutotranslateUTF8:YES];
	return self;
}


static inline id currentChildrenNoCheck( NSXMLElementInfo *base, int offset , MPWObjectCache *attributeCache ) {
	id children=nil;
	NSXMLElementInfo *info=&base[offset-1];
	children=info->children;
	if ( !children ) {
		info->children=GETOBJECT( attributeCache );
		children=info->children;
	}
	return children;
}


-currentChildren
{
	id children=nil;
    if (tagStackLen>0 ){
		children = currentChildrenNoCheck( _elementStack, tagStackLen, attributeCache );
	}
	return children;
}

-currentObject
{
	return [[self currentChildren] lastObject];
}

#ifdef PUSHOBJECT 
#undef PUSHOBJECT
#endif
#define PUSHOBJECT( anObject, aKey, aNamespace ) \
	if ( tagStackLen > 0 ) { \
		[currentChildrenNoCheck( ((NSXMLElementInfo*)_elementStack), tagStackLen, attributeCache )  setValueAndRelease:anObject forAttribute:aKey namespace:aNamespace]; \
	} else { \
		parseResult=anObject; \
	}\


-(void)pushObject:anObject forKey:aKey withNamespace:aNamespace
{
#if 0
	if ( tagStackLen > 0 ) {
		
	
		[currentChildrenNoCheck( ((NSXMLElementInfo*)_elementStack), tagStackLen, attributeCache )  setValueAndRelease:anObject forAttribute:aKey namespace:aNamespace];
//		[[self currentChildren]  setValueAndRelease:anObject forAttribute:aKey ];
	} else {
		parseResult=anObject;
	}
#else
	PUSHOBJECT( anObject, aKey, aNamespace );
#endif
}




-(void)initializeCharacterDataAllowedTags:(NSArray*)tags
{
//	characterDataAllowedTags=[[MPWSmallStringTable alloc] initWithKeys:tags values:tags];
}

-(BOOL)characterDataAllowed:parser
{
	return YES;
}

-(void)handleNameSpaceAttribute:name withValue:value
{
//	NSLog(@"namespace attribute: %@ value: %@",name,value);
	[namespacePrefixToURIMap setObject:[value stringValue] forKey:[name stringValue]];
	
}

-(MPWTagHandler*)handlerForPrefix:(const char*)prefixString length:(int)prefixLen
{
	MPWTagHandler* handler=nil;
	if (! prefix2HandlerMap ) {
		[self rebuildPrefixHandlerMap];
	}
//	NSLog(@"getting handler for prefix: '%.*s'",prefixLen,prefixString);
	handler = [prefix2HandlerMap objectForCString:(char*)prefixString length:prefixLen];
	if ( !handler ) {
		handler=defaultNamespaceHandler;
	}
	return handler;
}


-(BOOL)attributeName:(const char*)nameStart length:(int)nameLen value:(const char*)valueStart length:(int)valueLen namespaceLen:(int)namespaceLen
	/*"
	"*/
{
	const char *strippedStart;
	int strippedNameLen;
	id  handler=defaultNamespaceHandler;
	id name,value=nil,valueToRelease=nil;
	if ( tagStackLen > maxDepthAllowed ) {
		return YES;
	}
	if ( YES ) {
		int i;
		for (i=0;i< valueLen;i++ ) {
			if ( valueStart[i] & 128 ) {
				value = (id)CFMakeCollectable(CFStringCreateWithBytes(NULL, (unsigned char*)valueStart, valueLen, cfDataEncoding, NO));
				valueToRelease=value;
				break;
			}
		}
	}
	if ( !value ) {
		value = MAKEDATA( valueStart, valueLen );
	}
//	NSLog(@"name: '%.*s' value: '%.*s'",nameLen,nameStart,valueLen,valueStart);
	if (  extractNameSpace( nameStart, nameLen, &strippedStart, &namespaceLen, &strippedNameLen ) ) {
		name = MAKEDATA( strippedStart, strippedNameLen );
		if ( namespaceLen==5 && !strncmp( "xmlns", nameStart, 5 ) ) {
			[self handleNameSpaceAttribute:name withValue:value];
			return YES;
		}
		handler=[self handlerForPrefix:nameStart length:namespaceLen];
	} else {
		name = MAKEDATA( nameStart, nameLen );
	}
	if (  !_attributes && attributeCache ) {
//		NSLog(@"attributes, getObject: %p %p",attributeCache->getObject,[attributeCache getObjectIMP]);
		id att=GETOBJECT(  attributeCache);
		[self _setAttributes:att];
		[att removeAllObjects];
	}
//	NSLog(@"tag for '%@' in '%@' is %d",name, [namespacePrefixToURIMap objectForKey:MAKEDATA(nameStart,namespaceLen)] ,integerTagForAttributeName);
	[_attributes setValue:value forAttribute:name];

	return YES;
}




-(void)initializeActionMapWithTags:elementNames target:actionTarget
{
	id tagHandler=[[[MPWTagHandler alloc] init] autorelease];
	[tagHandler initializeActionMapWithTags:elementNames target:actionTarget];
//	NSLog(@"initializeActionMapWithTags: %@ target: %@",elementNames,target);
	[self setDefaultNamespaceHandler:tagHandler];
}

-createNamespaceHandlerIfNecessary:(NSString*)namespace
{
	id handler=namespace ? [namespaceHandlers objectForKey:namespace] : defaultNamespaceHandler ;
	if ( !handler ) {
        @autoreleasepool {
            handler=[[[MPWTagHandler alloc] init] autorelease];
            if ( namespace ) {
                [namespaceHandlers  setObject:handler forKey:namespace];
            } else {
                [self setDefaultNamespaceHandler:handler];
            }
        }
	}
	return handler;
}

-(id)declareAttributes:(NSArray*)attributes inNamespace:(NSString*)namespaceString  
{
	id tagHandler=[self createNamespaceHandlerIfNecessary:namespaceString];
	[tagHandler declareAttributes:attributes];
	return tagHandler;
}


-(id)setHandler:handler forElements:(NSArray*)elementNames inNamespace:(NSString*)namespace prefix:(NSString*)prefix map:(NSDictionary*)map
{
	id tagHandler=[self createNamespaceHandlerIfNecessary:namespace];
	[tagHandler setExceptionMap:map];
	[tagHandler initializeActionMapWithTags:elementNames target:handler prefix:prefix];
	[tagHandler setUndeclaredElementHandler:handler backup:self];
	return tagHandler;
}

-(id)setHandler:handler forElements:(NSArray*)elementNames
{
    return [self setHandler:handler forElements:elementNames inNamespace:nil prefix:@"" map:nil];
}

-(id)setHandler:handler forTags:(NSArray*)tags inNamespace:(NSString*)namespaceString prefix:(NSString*)prefix map:(NSDictionary*)map
{
	id tagHandler=nil;
    
    @autoreleasepool {
        tagHandler=[[self createNamespaceHandlerIfNecessary:namespaceString] retain];
    }
    @autoreleasepool {
        [tagHandler initializeTagActionMapWithTags:tags caseInsensitive:[self ignoreCase] target:handler prefix:prefix];
    }
	return [tagHandler autorelease];
}

-(id)setHandler:handler forTags:(NSArray*)tags
{
    return [self setHandler:handler forTags:tags inNamespace:nil prefix:@"" map:nil];
}


idAccessor( prefix2HandlerMap, setPrefix2HandlerMap )

-(void)rebuildPrefixHandlerMap
{
	id pool=[NSAutoreleasePool new];
	id prefixes = [namespacePrefixToURIMap allKeys];
	id activePrefixes=[NSMutableArray array];
	id handlers = [NSMutableArray array];
	for (id key in prefixes ) {
		NSString *namespaceString= [namespacePrefixToURIMap objectForKey:key];
		id handler = [namespaceHandlers objectForKey:namespaceString];
		if ( handler ) {
			[handlers addObject:handler];
			[activePrefixes addObject:key];
//			NSLog(@"will set namespacestring: %@ for handler %p",namespaceString,handler);
			[handler setNamespaceString:namespaceString];
		}
	}
//	NSLog(@"handlers %@ for prefixes: %@",handlers,activePrefixes);
	[self setPrefix2HandlerMap:[[[MPWSmallStringTable alloc] initWithKeys:activePrefixes values:handlers] autorelease]];
	[pool release];
}

-(void)invalidateHandlerMap
{
	[self setPrefix2HandlerMap:nil];
}


- (void)parserDoStackProcessingForEndElementStartPtr:(const char*)fullyQualifedPtr len:(int)fullyQualifiedLen namespaceLen:(int)namespaceLen tag:tag
{
	const char *tagStartPtr=fullyQualifedPtr;
	int tagLen=fullyQualifiedLen;
	id result=nil;
	id handler=defaultNamespaceHandler;
//	namespaceLen=0;
	if ( tagStackLen >0 ) {
		NSXMLElementInfo *currentElement = &CURRENTELEMENT;
		id attrs=currentElement->attributes;
		id children = currentElement->children;
//		id *childPointer=[children _pointerToObjects];
		MPWFastInvocation* invocation; 
//		int childCount=[children count];
//		NSLog(@"parserDoStackProcessin attributes for %@ are: %@",CURRENTELEMENT.elementName,attrs);
        if ( namespaceLen){
			handler=[self handlerForPrefix:fullyQualifedPtr length:namespaceLen];
            tagStartPtr=fullyQualifedPtr+namespaceLen+1;
            tagLen=fullyQualifiedLen-namespaceLen-1;
        } else {
            tagStartPtr=fullyQualifedPtr;
            tagLen=fullyQualifiedLen;
        }
//		if (  extractNameSpace( fullyQualifedPtr, fullyQualifiedLen, &tagStartPtr, &namespaceLen, &tagLen ) ) {
//			NSLog(@"handler for fully qualifed : '%.*s' is %@",fullyQualifiedLen,fullyQualifedPtr,handler);
//        }
		int integerTag = 0; // [handler integerTagForElementName:tagStartPtr length:tagLen];
		currentElement->integerTag=integerTag;
//		NSLog(@"integer tag: %d",integerTag);
#if 0
		NSLog(@"parserDoStackProcessingForEndElementStartPtr: '%.*s' with '%.*s' and '%.*s'",
			fullyQualifiedLen,fullyQualifedPtr,
			namespaceLen,fullyQualifedPtr,
			tagLen,tagStartPtr);
//		NSLog(@"parserDoStackProcessingForEndElementStartPtr: tagStackLen = %d children = %@",tagStackLen,children);
#endif	
			invocation = [handler elementHandlerInvocationForCString:tagStartPtr length:tagLen];
			{
				id args[3]={ children, attrs ,self};
//				NSLog(@"will invoke: %@/%@",[invocation target],NSStringFromSelector([invocation selector]));
				result = [invocation resultOfInvokingWithArgs:args count:3];
//				NSLog(@"did invoke");
			}
		[children removeAllObjects];
		[CURRENTELEMENT.attributes release]; //=retainMPWObject( attrs ) ;
		CURRENTELEMENT.attributes=nil;
		[tag retain];
		POPTAG;
		if ( result ) {
//			int integerTag = [handler integerTagForElementName:tagStartPtr length:tagLen];

//			if ( integerTag < 0 ) {
//				NSLog(@"couldn't get integer tag for '%.*s' from %@",tagLen,tagStartPtr,handler);
//			}
//			NSLog(@"push for tag: %@ handler: %p %@",tag,handler,[handler namespaceString]);
			PUSHOBJECT( result, tag, handler );
		}
		[tag release];
//		[attrs removeAllObjects];
	
	
//		NSLog(@"got an invocation: %@ for '%.*s'",invocation,len,startPtr);
//			objectStack[start-1]=[self processElementName:endName attributes:attrs objects:objectStack+start count:numElementsToPop];
//		[self popAndRelease:result ? numElementsToPop : numElementsToPop+1];
//		[attrs release];
	} else {
		NSLog(@"--- trying to process end element with empty stack");
	}
}




-(BOOL)beginElement:(const char*)fullyQualifedPtr length:(int)len nameLen:(int)fullyQualifiedLen namespaceLen:(int)namespaceLen
{
	const char *tagStartPtr=fullyQualifedPtr;
	int tagLen=fullyQualifiedLen;
   id tag=nil;
    BOOL isEmpty=NO;
	id handler=defaultNamespaceHandler;
 	NSXMLElementInfo *currentElement = (((NSXMLElementInfo*)_elementStack)+tagStackLen );
	RECORDSCANPOSITION( fullyQualifedPtr, len );
	if ( currentElement ) {
		currentElement->start = fullyQualifedPtr;
		currentElement->fullyQualifiedLen = fullyQualifiedLen;
	}

	if (  charactersAreSpace &&  !reportIgnoreableWhitespace) {
//		NSLog(@"characters before begin: %.*s were space",nameLen,start);
		[self flushPureSpace];
    }

	lastTagWasOpen=YES;
	charactersAreSpace=YES;
    if ( fullyQualifedPtr[len-2]=='/' ) {
		// trailing '/>' means this is an empty element
        isEmpty=YES;
        if ( fullyQualifedPtr[fullyQualifiedLen-1]=='/' ) {
			//  if it's  '<name/>', we must also adjust the name length
            fullyQualifiedLen--;
        }
    }
    //--- remove brackets from name
    fullyQualifedPtr++;
    fullyQualifiedLen--;
    len-=2;

    //--- support for partial parsing to a specified depth (for lazy DOM parser...)
	if ( tagStackLen > maxDepthAllowed ) {
		NSXMLElementInfo* previous=(((NSXMLElementInfo*)_elementStack)+tagStackLen-1 );
		previous->isIncomplete=YES;

		if (!isEmpty) {
			PUSHTAG( ((id)nil) );
		} else {
			lastTagWasOpen=NO;
		}
		return YES;
	}
	currentElement->isIncomplete=NO;
    if ( fullyQualifiedLen > 0 ) {
		id attrs=_attributes;
//		id prefixTag=nil;
        if ( namespaceLen > 0) {
            namespaceLen-=1;
            tagLen-=namespaceLen+2;
            tagStartPtr=fullyQualifedPtr+namespaceLen+1;
			handler=[self handlerForPrefix:fullyQualifedPtr length:namespaceLen];
        } else {
            tagStartPtr=fullyQualifedPtr;
            tagLen=fullyQualifiedLen;
        }
		if ( tagLen == 4 && !strncasecmp(tagStartPtr, "meta", 4) ) {
			[self handleMetaTag];
		}
		if ( handler ) {
			tag=[handler getTagForCString:tagStartPtr length:tagLen];
//			NSLog(@"got unique tag: '%@',%p non-unique: '%@'",tag,tag,TAGFORCSTRING( fullyQualifedPtr, fullyQualifiedLen));
		}
		if ( !tag ) {
			tag=TAGFORCSTRING( fullyQualifedPtr, fullyQualifiedLen);
		}
        PUSHTAG( tag);
#if 0
		NSLog(@"begin element: <%@> stackDepth %d stack: %@",tag,tagStackLen,[self _fullTagStackString]);
#endif	
//		NSLog(@"beginelement: %@/%x",documentHandler,beginElement);
#if 1
		if ( !attrs ) {
			 id _emptyDict=nil;
			if ( !_emptyDict ) {
				_emptyDict=GETOBJECT( (MPWObjectCache*)attributeCache ); //  [[NSXMLAttributes alloc] init];
				[_emptyDict removeAllObjects];
			}
			attrs=_emptyDict;
		}
#endif		
//		fprintf(stderr,"BEGINELEMENT: self=%p beginElement: %p documentHandler: %p\n",self,beginElement,documentHandler);
		CURRENTELEMENT.attributes=retainMPWObject( attrs ) ;
		if ( ! CURRENTELEMENT.children ) {
			CURRENTELEMENT.children=[[MPWXMLAttributes alloc] init];
		} else {
			[CURRENTELEMENT.children removeAllObjects];
		}
//		PUSHOBJECT( retainMPWObject( attrs ) );
#if 1
		if ( 1 ) {
			id invocation = [handler tagHandlerInvocationForCString:tagStartPtr length:tagLen];
			{
				id args[2]={  attrs, self };
				[invocation resultOfInvokingWithArgs:args count:2];
			}
		}
#endif
		
		if ( _attributes ) {
			[self clearAttributes];
		}
        if ( isEmpty ) {
//			NSLog(@"empty element with '%.*s'",nameLen,start);

//            [tag retain];
			[self parserDoStackProcessingForEndElementStartPtr:fullyQualifedPtr len:fullyQualifiedLen namespaceLen:namespaceLen tag:tag];
			lastTagWasOpen=NO;
//			NSLog(@"after empty element with '%.*s'",nameLen,start);
//			NSLog(@"finished processing empty element");
//           [tag release];
//		   allowedIndex--;
        }
    } else {
        NSLog(@"nameLen <= 0!");
    }
//	NSLog(@"begin tag (end), tagStackLen: %d",tagStackLen);
    return YES;
}    

-(BOOL)isCurrentElementIncomplete
{
	return CURRENTELEMENT.isIncomplete;
}

-(void)reportIgnoredWhitespace
{
   for (int i=0; i<numSpacesOnStack;i++) {
        PUSHOBJECT( [@" " retain] /* [MAKEDATA( start, len ) retain] */ ,MPWXMLPCDataKey, nil );
    }
    numSpacesOnStack=0;
}

-(void)flushPureSpace
{
    numSpacesOnStack=0;
    if ( numSpacesOnStack) {
//        [[self currentChildren] pop:numSpacesOnStack];
    }
}

-(BOOL)endElement:(const char*)fullyQualifedPtr length:(int)fullyQualifiedLen namespaceLen:(int)namespaceLen
{
	const char *startPtr;
	int tagLen;
	id endName=nil;

	
    RECORDSCANPOSITION( fullyQualifedPtr, fullyQualifiedLen );
    fullyQualifedPtr+=2;
    fullyQualifiedLen-=3;
	startPtr=fullyQualifedPtr;
	tagLen=fullyQualifiedLen;
	int len=tagLen;
	id handler=defaultNamespaceHandler;
	NSXMLElementInfo *currentElement = &CURRENTELEMENT;
//	allowedIndex--;

    
	if ( currentElement ) {
		currentElement->end = startPtr + len+1;
//        NSLog(@"currentElement tag name: '%.*s'",currentElement->fullyQualifiedLen-1,currentElement->start+1);
//        NSLog(@"endElement = '%.*s'",fullyQualifiedLen,fullyQualifedPtr);
        if ( fullyQualifiedLen == currentElement->fullyQualifiedLen-1) {
            const char *p1=currentElement->start+1;
            const char *p2=fullyQualifedPtr;
            const char *p1end=p1+fullyQualifiedLen;
            int len=fullyQualifiedLen;
            BOOL ok=YES;
            while ( p1 < p1end) {
                if ( *p1++ != *p2++ ) {
                    ok=NO;
                    break;
                }
            }
            if ( ok) {
                endName=currentElement->elementName;
            }
        }
	}
	
//	NSLog(@"end tag, tagStackLen: %d",tagStackLen);
	if ( tagStackLen-1 > maxDepthAllowed ) {
//		NSLog(@"endElement going to skip at level %d, children: %x",tagStackLen,currentElement->children);
		POPTAG;
//		NSLog(@"after pop %d",tagStackLen);
		lastTagWasOpen=NO;
		return YES;
	}
    if ( namespaceLen > 0) {
        tagLen-=namespaceLen-1;
        startPtr=fullyQualifedPtr+namespaceLen-1;
        namespaceLen-=2;
       handler=[self handlerForPrefix:fullyQualifedPtr length:namespaceLen];
//        NSLog(@"startPtr: %.*s namespace: '%.*s'",tagLen,startPtr,namespaceLen,fullyQualifedPtr);
    } else {
        startPtr=fullyQualifedPtr;
        tagLen=fullyQualifiedLen;
    }
    
	if ( !endName && handler ) {
		endName=[handler getTagForCString:startPtr length:tagLen];
	}
	if ( !endName ) {
//        NSLog(@"did not get endName ('%.*s') from handler %@",tagLen,startPtr,handler);
		endName=TAGFORCSTRING( fullyQualifedPtr, fullyQualifiedLen);
	}
	
#if 0
		NSLog(@"end element: <%@> stackDepth %d stack: %@",endName,tagStackLen,[self _fullTagStackString]);
#endif	

	if ( !lastTagWasOpen && charactersAreSpace && !reportIgnoreableWhitespace ) {
//		NSLog(@"characters before end: %.*s were space",len,startPtr);
		[self flushPureSpace];
    }
	charactersAreSpace=YES;
	numSpacesOnStack=0;
	lastTagWasOpen=NO;
    if ( CURRENTTAG == endName || [CURRENTTAG isEqual: endName] ) {
//        NSLog(@"will do stackProcessing tag: %@",CURRENTTAG);
		[self parserDoStackProcessingForEndElementStartPtr:fullyQualifedPtr len: fullyQualifiedLen namespaceLen:namespaceLen tag:CURRENTTAG];
//		NSLog(@"end tag end, tagStackLen: %d",tagStackLen);
        return YES;
    } else {
		if ( enforceTagNesting ) {
			[self setParserError:[NSError errorWithDomain:@"XML" code:76 userInfo:nil]];
			[NSException raise:@"non-matching tags" format:@"non matching tags start tag '%@' end tag '%@'",[self currentTag],endName];
			return NO;
		} else {
			while (  tagStackLen>0  && ![CURRENTTAG isEqual: endName] ) {
				NSLog(@"stack[%ld] non matching end-tags: on-stack '%@' close-tag encountered: '%@'",tagStackLen,CURRENTTAG,endName);
				POPTAG;
			}
			return YES;
		}
    }
}

//--- need to cut this off for the time being

-defaultElement1:values attributes:attributes parser:parser
{
	return nil;
}


- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)chars
{
//	NSLog(@"parser: foundCharacters:'%@'",characters);
    if ( tagStackLen > 0 && tagStackLen < maxDepthAllowed ){
		charactersAreSpace=NO;
        PUSHOBJECT(  [chars retain], MPWXMLPCDataKey, nil );
    } else {
//        NSLog(@"pre-data: '%@'",chars);
    }
}

-(void)parser:(NSXMLParser *)parser foundCDATA:(NSData*)chars
{
    if ( tagStackLen > 0 && tagStackLen < maxDepthAllowed){
		charactersAreSpace=NO;
        PUSHOBJECT( [chars retain] ,MPWXMLCDataKey, nil );
    } else {
//        NSLog(@"pre-data: '%@'",chars);
    }
}

-(BOOL)makeSpace:(const char*)start length:(int)len 
{
	RECORDSCANPOSITION( start, len );
	if (  tagStackLen > 0 && tagStackLen < maxDepthAllowed/* && lastTagWasOpen */ ) {
		numSpacesOnStack++;
//     PUSHOBJECT( [@" " retain] /* [MAKEDATA( start, len ) retain] */ ,MPWXMLPCDataKey, nil );
//	   NSLog(@"after space push, currentElement: %@",[self currentChildren]);
    } else {
//		NSLog(@"suppressing characters, tagStackLen: %d",tagStackLen);
	}
    return YES;
}

-(void)dealloc
{
	int i;
    
	[namespacePrefixToURIMap release];
	[defaultNamespaceHandler release];
	[namespaceHandlers release];
	[prefix2HandlerMap release];
//	NSLog(@"-[%p:%@ dealloc] stack tagStackLen: %d",self,[self class],tagStackLen );
    [dataCache release];
	[scanner release];
    scanner=nil;
	[data release];
	[url release];
    [self setDelegate:nil];
    [attributeCache release];
	for (i=0;i<tagStackCapacity;i++) {
		NSXMLElementInfo *info=&((NSXMLElementInfo*)_elementStack)[i];
		if ( info->children ) {
			[info->children release];
		}
		if ( info->attributes ) {
			[info->attributes release];
		}
	}
	while ( tagStackLen > 0 ) {
		POPTAG;
	}
    [parseResult release];
    free( _elementStack );
    [_attributes release];
//	[namespacePrefixToURIMap release];
//	[defaultNamespacePrefixURI release];
	[emptyDict release];
	[buffer release];
	[parserError release];
	[super dealloc];
}


-(void)setCharacterHandlerWithDocumentHandler:newCharHandler
{
	characterHandler=self;
}



static IMP unknownMethod;

+parser
{
	return [[[self alloc] init] autorelease];
}


-(IMP)methodForSelector:(SEL)sel forReceiver:receiver withDefault:(IMP)defaultMethod
{
	IMP result = defaultMethod;
	if ( [receiver respondsToSelector:sel] ) {
		IMP theMethod = [receiver methodForSelector:sel];
		if ( !unknownMethod ) {
			unknownMethod = [self methodForSelector:@selector(thisOneDoesntExistAtAll)];
		}
		if ( theMethod != (IMP)NULL  && theMethod != unknownMethod) {
			result = theMethod;
		} else {
//			NSLog(@"couldn't find method for %@ in %@",NSStringFromSelector(sel),[receiver class]);
		}
	}
//	NSLog(@"IMP for -[%@ %@] with default %x = %x",[self class],NSStringFromSelector(sel),result,defaultMethod);
	return result;
}


-(IMP)defaultedVoidMethodForSelector:(SEL)sel forReceiver:receiver
{
	return [self methodForSelector:sel forReceiver:receiver withDefault:(IMP)doNothing];
}

-(IMP)boolMethodForSelector:(SEL)sel defaultValue:(BOOL)defaultValue forReceiver:receiver
{
 	return [self methodForSelector:sel forReceiver:receiver withDefault:defaultValue ? (IMP)returnYes : (IMP)returnNo];
}


-(void)_growTagStack:(unsigned)newCapacity
{
//    NSLog(@"growStack to: %d",newCapacity);
	void *newStack = ALLOC_POINTERS( (newCapacity+10)* sizeof (NSXMLElementInfo)  );
	memset( newStack, 0,  (newCapacity+5) * sizeof (NSXMLElementInfo) );
	memcpy( newStack, _elementStack, tagStackCapacity * sizeof (NSXMLElementInfo) );
	_elementStack=newStack;
    tagStackCapacity=newCapacity;
}

-delegate
{
	return [self documentHandler];
}

-(void)setDelegate:handler
{
    [self _setDocumentHandler:handler];
    beginElement = [self defaultedVoidMethodForSelector:BEGINELEMENTSELECTOR forReceiver:handler];
//	NSLog(@"beginElement: %x for %@",beginElement,NSStringFromSelector(BEGINELEMENTSELECTOR));
    endElement = [self defaultedVoidMethodForSelector:ENDELEMENTSELECTOR  forReceiver:handler];
//	NSLog(@"endElementSelector: %@",NSStringFromSelector(ENDELEMENTSELECTOR));

	characterDataAllowed = [self boolMethodForSelector:@selector(characterDataAllowed:) defaultValue:YES forReceiver:self ];

	[self setCharacterHandlerWithDocumentHandler:handler];

    characters = [self defaultedVoidMethodForSelector:CHARACTERSSELECTOR forReceiver:characterHandler];
    cdata = [self defaultedVoidMethodForSelector:CDATASELECTOR forReceiver:characterHandler];
//    NSLog(@"document-handler now %@",documentHandler);
}



-(NSInteger)currentElementNestingLevel
{
	return tagStackLen;
}

-(NSString *)elementNameAtNestingLevel:(NSInteger)depth
{
	if ( depth >= 0 && depth < tagStackLen ) {
		return ((NSXMLElementInfo*)_elementStack)[depth].elementName;
	}
	return nil;
}

-(id <NSXMLAttributes>)elementAttributesAtNestingLevel:(NSInteger)depth
{
	if ( depth >= 0 && depth < tagStackLen ) {
		return ((NSXMLElementInfo*)_elementStack)[depth].attributes;
	}
	return nil;
}

-(NSInteger)currentIntegerTag;
{
    return CURRENTINTEGERTAG;
}

-currentTag
{
    return CURRENTTAG;
}

-(void)popTag
{
    POPTAG;
}

-(void)pushTag:aTag
{
    PUSHTAG(aTag);
}

typedef char xmlchar;
//#import "XmlDelimitAttrValues.h"

-getTagForCString:(const char*)cstr length:(int)len
{
	return MAKEDATA( cstr, len );
}


-_fullTagStackString
{
	NSMutableString *stackStr=[NSMutableString string];
	int i;
	for (i=0;i<tagStackLen;i++) {
		[stackStr appendFormat:@"%@/",((NSXMLElementInfo*)_elementStack)[i].elementName];
	}
	return stackStr;
}


-makeData:(const char*)start length:(int)length
{
	return initDataBytesLength( getData( dataCache, @selector(getObject)),@selector(reInitWithData:bytes:length:), data, start , length );

//	return MAKEDATA( start, len );
}	



-(void)clearAttributes
{
	[self _setAttributes:nil];
}

-(BOOL)makeText:(const char*)start length:(int)len firstEntityOffset:(int)entityOffset
{
	id	stringToRelease=nil;
	id  str=nil;
//	NSLog(@"%d characters:  '%@' entityOffset: %d tagStackLen: %d self: %x",len,MAKEDATA(start,len),entityOffset,tagStackLen,self);
	RECORDSCANPOSITION( start, len );
	if ( entityOffset > 0 ) {
		
	}
    if (  CHARACTERDATAALLOWED  ) {
		int i;
//		NSLog(@"allowing characters, tagStackLen: %d and sending to %@",tagStackLen,characterHandler);
		if ( autotranslateUTF8 ) {
			for (i=0;i< len;i++ ) {
				if ( start[i] & 128 ) {
					str = (id)CFMakeCollectable(CFStringCreateWithBytes(NULL, (const unsigned char*)start, len, cfDataEncoding, NO));
					stringToRelease=str;
//					if (!str ) { return YES; }
					break;
				}
			}
		}
		if ( !str ) {
			str= MAKEDATA( start, len );
		}
		if ( str ) {
			CHARACTERS( str );
		}
		[stringToRelease release];
		//					NSLog(@"translated string: %@",str);
		return YES;
    } else {
//		NSLog(@"suppressing characters, tagStackLen: %d",tagStackLen);
	}
    return YES;
}



-(BOOL)makeCData:(const char*)start length:(int)len
{
    int cdlen = sizeof "<![CDATA[" - 1;
	RECORDSCANPOSITION( start, len );
    start+=cdlen;
    len-=cdlen+3;
//	NSLog(@"%d cdata ",len);
// 	NSLog(@"%d characters:  '%@' tagStackLen: %d",len,MAKEDATA(start,len),tagStackLen);
   if ( CHARACTERDATAALLOWED ) {
        CDATA(MAKEDATA( start,len ));
		//--- also have to check for non '@' valueType
    }
    return YES;
}

-(BOOL)makeSgml:(const char*)start length:(int)len nameLen:(int)nameEnd
/*"
"*/
{
//    id sg=MAKEDATA( start,len);
//    NSLog(@"declaration: %@",sg);
	RECORDSCANPOSITION( start, len );
    return YES;
}

-resolvePredefinedInternalEntity:(const xmlchar*)start length:(int)len
{
	id	resolved=nil;
//	NSLog(@"will try to resolve predefined entity %.*s",len,start);
	if ( len == 2 && start[1]=='t') {
		if ( start[0] == 'l') {
			resolved = @"<";
		} else if ( start[0]=='g' ) {
			resolved=@">";
		}
	} else if ( len == 3 && !strncmp( "amp" , (char*)start,3 ) ) {
		resolved = @"&";
	} else if ( len == 4 && start[0]!='#') {
		if ( !strncmp( "apos",(char*)start,4 ) ) {
			resolved = @"'";
		} else if ( !strncmp( "quot", (char*)start, 4 ) ) {
			resolved = @"\"";
		}
	} else if ( start[0]=='#'  ) {
		char *conversionString="%d";
		char buffer[20];
		
		if ( tolower( start[1]) =='x' ) {
			start++;
			conversionString="%x";
		}
		int value;
		unichar univalue;
		memcpy( buffer, start+1, 16 );
		buffer[16]=0;
		sscanf(buffer, conversionString,&value);
		univalue=value;
		resolved=[NSString stringWithCharacters:&univalue length:1];
	}
//	NSLog(@"resolved: '%@'",resolved);
	return resolved;
}

-(BOOL)makeEntityRef:(const xmlchar*)start length:(int)len
{
	id resolved;
	RECORDSCANPOSITION( start, len );
	start++;	// remove leading '&'
	len--;
	if ( start[len-1]==';' ) {		//--- remove trailing ';' only if it is there
		len--;						//--- should always be the case, but isn't
	}
//	NSLog(@"entity ref (length %d): '%@'",len,MAKEDATA( start, len ));
	if ( nil != (resolved=[self resolvePredefinedInternalEntity:start length:len] ) ) {
		CHARACTERS(resolved);
	} else {
		id name=MAKEDATA(start,len);
//		NSLog(@"entity: '%@'",name);
		if ( [documentHandler respondsToSelector:@selector(parser:resolveExternalEntityName:systemID:)] ) {
			[documentHandler parser:(NSXMLParser*)self resolveExternalEntityName:name systemID:nil];
		}
	}
    return YES;
}

#if WINDOWS
#define kCFStringEncodingInvalidId (0xffffffffU)

CFStringEncoding CFStringConvertIANACharSetNameToEncoding(CFStringRef self) {
	id encodingstring=[(NSString*)self uppercaseString];
	if ( [encodingstring isEqual:@"UTF-8"] ) {
		return kCFStringEncodingUTF8;
	} else if ( [encodingstring isEqual:@"ISO-8859-1"] ) {
		return kCFStringEncodingISOLatin1;
	} else if ( [encodingstring isEqual:@"WINDOWS-1252"] ) {
		return kCFStringEncodingWindowsLatin1;
	}
	NSLog(@"unknown encoding string %@",self);
	 return kCFStringEncodingInvalidId;
}
	 
CFUInteger CFStringConvertEncodingToNSStringEncoding(CFStringEncoding encoding) {
	NSStringEncoding result=encoding;
	switch ( encoding) {
		case kCFStringEncodingUTF8:
			result=NSUTF8StringEncoding;
			break;
		case kCFStringEncodingISOLatin1:
			result=NSISOLatin1StringEncoding;
			break;
		case kCFStringEncodingWindowsLatin1:
			result=NSWindowsCP1252StringEncoding;
			break;
		default:
			NSLog(@"unknown cfstring encoding %d",encoding);
			break;
	}
	return result;
}

CFStringEncoding CFStringConvertNSStringEncodingToEncoding(CFUInteger encoding) {
	CFStringEncoding result=kCFStringEncodingUTF8;
	switch ( encoding) {
		case NSUTF8StringEncoding :
			result=kCFStringEncodingUTF8;
			break;
		case NSISOLatin1StringEncoding:
			result=kCFStringEncodingISOLatin1;
			break;
		case NSWindowsCP1252StringEncoding:
			result=kCFStringEncodingWindowsLatin1;
			break;
		default:
			NSLog(@"unknown nsstring encoding %d",encoding);
			break;
	}
	
	return result;
}

#endif

#ifndef kCFStringEncodingInvalidId
#define kCFStringEncodingInvalidId (0xffffffffU)
#endif

-(void)setStringEncodingFromIANACharset:(NSString*)charSetName
{
	CFStringEncoding cf_encoding = CFStringConvertIANACharSetNameToEncoding( (CFStringRef)charSetName );
	if ( cf_encoding != kCFStringEncodingInvalidId ) {
		NSStringEncoding computed = CFStringConvertEncodingToNSStringEncoding( cf_encoding );
		[self setDataEncoding:computed];
	} else {
		NSLog(@"unknown encoding: %@",charSetName);
	}
}


-(BOOL)makePI:(const xmlchar*)start length:(int)len nameLen:(int)nameLen
    /*"
    Call-back for a processing instruction.  Includes the full tag, including
    the open and close braces.
"*/
{
    id tag;
    const xmlchar *attrStart;
    int attrLen;
	id encoding;
	RECORDSCANPOSITION( start, len );
    start+=2;
    nameLen-=2;
    len-=3;
    attrStart=start+nameLen+1;
    attrLen=len-nameLen-1;
	id localVersion;
	tag = TAGFORCSTRING( start, nameLen);
	encoding = [_attributes objectForKey:@"encoding"];
	if ( encoding ) {
		[self setStringEncodingFromIANACharset:encoding];
	}
	localVersion = [_attributes objectForKey:@"version"];
	if ( localVersion ) {
		[self setVersion:localVersion];
	}
	if ( [documentHandler respondsToSelector:@selector(parser:foundProcessingInstructionWithTarget:data:)] ) {
		[documentHandler parser:(NSXMLParser*)self foundProcessingInstructionWithTarget:tag data:(NSString*)_attributes];	// FIXME
	}
	[self clearAttributes];
    return YES;
}

-(BOOL)parseFragment:(NSData*)nextData
{
//	id oldData=[[self data] retain];
	BOOL scanComplete;
	if ( buffer ) {
		[buffer appendData:nextData];
		nextData=buffer;
	}
	[self setData:nextData];
	lastGoodPosition=[nextData bytes];
	scanComplete=[scanner parse:nextData];
	if ( !scanComplete ) {
		int remainderOffset=(char*)lastGoodPosition-(char*)[nextData bytes];
		int remainderLength=[nextData length]-remainderOffset;
		if ( remainderLength >0 ) {
//			NSLog(@"scan failure with offset: %d length: %d at '%c'",remainderOffset,remainderLength,*lastGoodPosition);
			[self setBuffer:[NSMutableData dataWithBytes:lastGoodPosition length:remainderLength]];
		} else {
			[self setBuffer:nil];			//  must clear buffer if there was no remainder
			NSLog(@"non-positive remainder length: %d",remainderLength);
		}
	} else {
		[self setBuffer:nil];			//  must clear buffer if there was no remainder
	}
//	[self setData:oldData];
//	[oldData release];
	return scanComplete;
}

-(BOOL)parseSource:(NSEnumerator*)aSource
{
	NSData *nextData=nil;
	BOOL success=YES;
	[self setParserError:nil];
	NS_DURING
	if ( [documentHandler respondsToSelector:@selector(parserDidStartDocument:) ] ) {
		[documentHandler parserDidStartDocument:(NSXMLParser*)self];
	}
		while (  nil!= (nextData=[aSource nextObject]) ) {
			[self parseFragment:nextData];
		}
	if ( [documentHandler respondsToSelector:@selector(parserDidEndDocument:) ] ) {
		[documentHandler parserDidEndDocument:(NSXMLParser*)self];
	}
	NS_HANDLER
	if ( ![[localException name] isEqual:@"abort"] ) {
		NSLog(@"got exception: %@",localException);
		success=NO;
//		[localException raise];
	} else {
		NSLog(@"got abort, success=%d",success);
	}
	NS_ENDHANDLER
	return success;
}

-(BOOL)parse:(NSData*)someData
{
	BOOL success=NO;
	if ( someData ) {
		success = [self parseSource:[[NSArray arrayWithObject:someData] objectEnumerator]];
	}
	return success;
}

-(id)parsedData:(NSData*)someData
{
	if ( [self parse:someData] ) {
		return [self parseResult];
	} else {
		return nil;
	}
}

-(BOOL)startParsingFromURL:(NSURL*)xmlUrl
{
	BOOL success=YES;
	if ( [xmlUrl isFileURL] ) {
		//		NSLog(@"isFileURL: %@",xmlUrl);
		return [self parse:[NSData dataWithContentsOfURL:xmlUrl]];
	} else {
		NS_DURING
//		downloader = [[[MPWCachingDownloader alloc] init] autorelease];
		NSMutableURLRequest *theRequest = [NSMutableURLRequest requestWithURL:xmlUrl];
		//		NSLog(@"theRequest: %@",theRequest);
		[theRequest setValue:@"ObjectiveXML" forHTTPHeaderField:@"User-Agent"];
		[theRequest setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"]; 
		isReceivingData=YES;
		id connection=[[[NSURLConnection alloc] initWithRequest:theRequest delegate:self] autorelease];
		if ( [documentHandler respondsToSelector:@selector(parserDidStartDocument:) ] ) {
			[documentHandler parserDidStartDocument:(NSXMLParser*)self];
		}
		NS_HANDLER
		if ( ![[localException name] isEqual:@"abort"] ) {
			NSLog(@"got exception: %@",localException);
			success=NO;
		} else {
			NSLog(@"got abort");
		}
		NS_ENDHANDLER
		
		//		NSLog(@"started the connection: %@",connection);
	}
	return success;
}

-(BOOL)parseDataFromURL:(NSURL*)xmlUrl
{
	BOOL success=YES;
//	NSLog(@"parseDataFromURL: %@",xmlUrl);
	if (  [self startParsingFromURL:xmlUrl] ) {
		NS_DURING
		while (  isReceivingData ) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
//			NSLog(@"loop did run");
		}
//		NSLog(@"end of loop");
		NS_HANDLER
		if ( ![[localException name] isEqual:@"abort"] ) {
			NSLog(@"got exception: %@",localException);
			success=NO;
		} else {
			NSLog(@"got abort");
		}
		NS_ENDHANDLER
	}
	return success;
}

-(id)parsedDataFromURL:urlOrString
{
	NSURL *theUrl=(NSURL*)urlOrString;
//	NSLog(@"parsedDataFromURL: %@",theUrl);
	if ( [theUrl isKindOfClass:[NSString class]] ) {
		theUrl=[NSURL URLWithString:(NSString*)theUrl];
	}
	if ( [self parseDataFromURL:theUrl] ) {
		return [self parseResult];
	} else {
		return nil;
	}
}

-(BOOL)parse
{
	if ( [self data] ) {
		return [self parse:[self data]];
	} else if ( [self url] ) {
		return [self parseDataFromURL:[self url]];
	} else {
		[NSException raise:@"nodata" format:@"no data or URL specified"];
		return NO;
	}
}

-(void)abortParsing
{
	[NSException raise:@"abort" format:@"parsing aborted"];
}

-bytesForCurrentElement
{
	NSXMLElementInfo *currentElement = &CURRENTELEMENT;
	if ( currentElement && tagStackLen > 0 && currentElement->start && currentElement->end > currentElement->start ) {
		const char * start = currentElement->start;
		const char * end = currentElement->end;
		int len=end-start;
		return MAKEDATA( start , len );
	} else {
		return nil;
	}
}

-buildDOMWithChildren:(MPWXMLAttributes*)children attributes:(id <NSXMLAttributes>)attrs parser:(MPWMAXParser*)parser
{
    MPWXmlElement *element;
	NSArray *sub=nil;
	int count = [children count];
	id *objs=[children _pointerToObjects];
    if ( count > 0 ) {
		sub=[NSArray arrayWithObjects:objs count:count];
    }
    element=[[MPWXmlElement alloc] init];
	[element setElementBytes:[parser bytesForCurrentElement]];
    [element setName:CURRENTTAG];
	if ( [parser isCurrentElementIncomplete] ) {
		[element setIsIncomplete:YES];
	}
    if ( attrs ) {
        [element setAttributes:attrs];
    }
    if ( sub ) {
        [element setSubelements:sub];
		for (id elem in sub ) {
			if ( [elem respondsToSelector:@selector(setParent:)] ) {
				[elem setParent:element];
			}
		}
    }
    return element;
}

-buildChildren:(MPWXMLAttributes*)children attributes:(id <NSXMLAttributes>)attrs parser:(MPWMAXParser*)parser
{
	id result=nil;
	if ( [children isLeaf] ) {
		result=[[children combinedText] retain];
		if (!result ) {
			result=[attrs copy];
		}
	} else {
		result=[attrs copy];
		[children copyKeysTo:result];
	}
//	NSLog(@"tag %@ buildDOMWithChildren: %@ from children: %@ ",[self currentTag], result,children);
	return result;
}


-undeclaredElement:(MPWXMLAttributes*)children attributes:(MPWXMLAttributes*)attrs parser:(MPWMAXParser*)parser
{
	switch (undefinedTagAction) {
		case MAX_ACTION_DOM:
			return [self buildDOMWithChildren:children attributes:attrs parser:parser];
		case MAX_ACTION_PLIST:
			return [self buildPlistWithChildren:children attributes:attrs parser:parser];
		case MAX_ACTION_CHILDREN:
			return [self buildChildren:children attributes:attrs parser:parser];
		default:
			return nil;
	}
}

-defaultElement:(MPWXMLAttributes*)children attributes:(MPWXMLAttributes*)attrs parser:(MPWMAXParser*)parser
{
	return [self undeclaredElement:children attributes:attrs parser:parser];
}

-buildPlistWithChildren:(MPWXMLAttributes*)children attributes:(MPWXMLAttributes*)attributes parser:(MPWMAXParser*)parser
{
	id result = nil;
	if ( [children count] > 0 ) {
		if ( [children isLeaf] ) {
			result = [children combinedText];
		} else {
			if ( [children count] >= 2 && 
				 [[children keyAtIndex:0] isEqual:[children keyAtIndex:1]] ) {
				result = [[children allValues] retain];
			} else {
				result = [[[children asDictionary] mutableCopy] autorelease];
				[result addEntriesFromDictionary:[attributes asDictionary]];
			}
		}
	} else if ( [attributes count] ) {
		result = [attributes asDictionary];
	} else {
        result = @"";
    }
	return [result retain];
}




-(BOOL)htmlAttributeLowerCaseNamed:(NSString*)lowerCaseAttributeName isEqualTo:(NSString*)attributeValue
{
	return [attributeValue compare:[self htmlAttributeLowerCaseNamed:lowerCaseAttributeName] options:NSCaseInsensitiveSearch] == NSOrderedSame;
}

-htmlAttributeLowerCaseNamed:(NSString*)lowerCaseAttributeName
{
	id value = [[self _attributes] objectForCaseInsensitiveKey:lowerCaseAttributeName];
#if 0
	if ( !value ) {
		value = [[self _attributes] objectForKey:[lowerCaseAttributeName uppercaseString]];
	}
#endif	
	//	NSLog(@"value: %@ forKey: %@",value,lowerCaseAttributeName);
	return value; ;
}

-(BOOL)handleMetaTag
{
	if ( [self htmlAttributeLowerCaseNamed:@"http-equiv" isEqualTo:@"content-type"]) {
		NSString* charSet = [[[[self htmlAttributeLowerCaseNamed:@"content"] lowercaseString] componentsSeparatedByString:@"charset="] lastObject];
		if ( charSet ) {
			[self setStringEncodingFromIANACharset:charSet];
		} else {
			NSLog(@"bogus charset declaration?  '%@'",[self _attributes]);
		}
		return YES;
	} else {
		return NO;
	}
}

#if NS_BLOCKS_AVAILABLE
-(void)handleElement:(NSString*)elementName withBlock:(id (^)(id elements, id attributes, id parser ))aBlock
{

	MPWTagHandler *handler=[self defaultNamespaceHandler];
	[handler setInvocation:[MPWBlockInvocation invocationWithBlock:aBlock] forElement:elementName];
}

#endif

@end

@implementation MPWMAXParser(urlLoading)

// Forward errors to the delegate.
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)ioError {
			isReceivingData=NO;
	[self setParserError:ioError];
	[NSException raise:@"connectionFailed" format:@"network error: %@",ioError];
}

// Called when a chunk of data has been downloaded.
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)receivedData {
//	NSLog(@"did receive:%d bytes: '%@'",[receivedData length],
//			[[[NSString alloc] initWithData:receivedData encoding:NSUTF8StringEncoding] autorelease]);
	[self parseFragment:receivedData];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	if ( [documentHandler respondsToSelector:@selector(parserDidEndDocument:) ] ) {
		[documentHandler parserDidEndDocument:(NSXMLParser*)self];
	}	
	isReceivingData=NO;
}


@end

#ifndef MPWXmlCoreOnly

#import "MPWXmlGeneratorStream.h"

@implementation MPWMAXParser(testing)

-initAsDomParser
{
    self = [self init];
	[self setHandler:self forElements:[NSArray array] inNamespace:nil prefix:@"" map:nil];
	[self setUndefinedTagAction:MAX_ACTION_DOM];
	return self;
}

+domParser
{
	return [[[self alloc] initAsDomParser] autorelease];
}


+(void)testEmptyParseDoesntRaiseAndSetsDefaultEncoding
{
	id xmldata=[self frameworkResource:@"test1" category:@"xml"];
	id parser=[self parser];
	NS_DURING
	[parser parse:xmldata];
	NS_HANDLER
		NSAssert1( NO, @"empty MAX parse raise: %@",localException);
	NS_ENDHANDLER
	INTEXPECT([parser dataEncoding], NSUTF8StringEncoding, @"string encoding after empty parse (default)");
}

+(void)testISOEncodingSetByXML
{
	id xmldata=[self frameworkResource:@"iso-encoded" category:@"xml"];
	id parser=[self parser];
	[parser parse:xmldata];
	INTEXPECT([parser dataEncoding], NSISOLatin1StringEncoding, @"ISO encoding should have been set from file");
}

+(void)testWindowsEncodingSetByXML
{
	id xmldata=[self frameworkResource:@"windows-encoded" category:@"xml"];
	id parser=[self parser];
	[parser parse:xmldata];
	INTEXPECT([parser dataEncoding], NSWindowsCP1252StringEncoding, @"Windows code page 1252 encoding should have been set from file");
}

+(void)testXMLVersion
{
	id xmldata=[self frameworkResource:@"windows-encoded" category:@"xml"];
	id parser=[self parser];
//	NSLog(@"parser version before parse: %@",[parser version]);
	[parser parse:xmldata];
//	NSLog(@"parser version: %@",[parser version]);
	IDEXPECT( [parser version],@"1.0", @"XML version should have been set from file");
}

+(void)testParseUndeclaredElementsToPlist
{
	id xmldata=[self frameworkResource:@"test3" category:@"xml"];
	id parser=[self parser];
	id expectedResults=[NSDictionary dictionaryWithObjectsAndKeys:@"content",@"nested1",@"content1",@"nested2",nil];
	[parser setUndefinedTagAction:MAX_ACTION_PLIST];
	[parser parse:xmldata];
	IDEXPECT( [parser parseResult] , expectedResults, @"testPlistParse");
}

+(void)testParseUndeclaredElementsToXMLAttributes
{
	id xmldata=[self frameworkResource:@"test3" category:@"xml"];
	id parser=[self parser];
	MPWXMLAttributes* parseResult;
	[parser setUndefinedTagAction:MAX_ACTION_CHILDREN];
	[parser parse:xmldata];
	parseResult=[parser parseResult];
	INTEXPECT( [parseResult count] , 2, @"count ");
	IDEXPECT( [parseResult objectForKey:@"nested1"] , @"content", @"first ");
	IDEXPECT( [parseResult objectForKey:@"nested2"] , @"content1", @"second ");
	IDEXPECT( [parseResult objectAtIndex:0] , @"content", @"first accessed as array ");
	IDEXPECT( [parseResult objectAtIndex:1] , @"content1", @"second accessed as array ");
}

+(void)testParseElementsToXMLAttributesWithUniqueKeys
{
	id xmldata=[self frameworkResource:@"test3" category:@"xml"];
	id parser=[self parser];
	id nestedKey1=@"nested1";
	id nestedKey2=@"nested2";

	MPWXMLAttributes* parseResult;
	[parser setUndefinedTagAction:MAX_ACTION_CHILDREN];
	[parser setHandler:parser forElements:[NSArray arrayWithObjects:nestedKey1,nestedKey2,nil]
		   inNamespace:nil prefix:@"" map:nil ];
	[parser parse:xmldata];
	parseResult=[parser parseResult];
//	NSLog(@"parseResult: %@",parseResult);
	INTEXPECT( [parseResult count] , 2, @"count ");
	IDEXPECT( [parseResult objectForKey:nestedKey1] , @"content", @"first ");
	IDEXPECT( [parseResult objectForUniqueKey:nestedKey1] , @"content", @"first ");
	IDEXPECT( [parseResult objectForUniqueKey:@"nested2"] , @"content1", @"second ");
}

+(void)testParseElementsToXMLAttributesWithNamespaces
{
	id xmldata=[self frameworkResource:@"tagconflict_disambiguated_by_namespace" category:@"xml"];
	id titleKey=@"title";
	id parser=[self parser];
	MPWXMLAttributes* parseResult;
	[parser setUndefinedTagAction:MAX_ACTION_CHILDREN];
	id ns1=[parser setHandler:parser forElements:[NSArray arrayWithObjects:titleKey,nil]
		   inNamespace:@"http://metaobject.com/ns1" prefix:@"" map:nil ];
	id ns2=[parser setHandler:parser forElements:[NSArray arrayWithObjects:titleKey,nil]
		   inNamespace:@"http://metaobject.com/ns2" prefix:@"" map:nil ];
	[parser parse:xmldata];
	parseResult=[parser parseResult];
	INTEXPECT( [parseResult count], 2, @"number of elements");
	IDEXPECT( [parseResult objectForUniqueKey:titleKey], @"First Title", @"first title, unqualified by namespace");
	IDEXPECT( [parseResult objectForUniqueKey:titleKey namespace:ns1], @"Second Title", @"second title, namspace1" );
	IDEXPECT( [parseResult objectForUniqueKey:titleKey namespace:ns2], @"First Title", @"first title, namspace2" );
}

+(void)testRecoverFromISOEncodingClaimingUTF8ResultingInIllegalByteSequences
{
	NSData* xmldata=[self frameworkResource:@"checkForPenApps_with_ISO8859_claiming_UTF8" category:@"xmlrpc"];
	MPWMAXParser *parser=[self parser];
	NSDictionary* result=[parser parsedData:xmldata];
	EXPECTNOTNIL( result, @"should be able to parse/recover");
	id topLevel=[result valueForKeyPath:@"params.param.value.struct"];
	INTEXPECT( [topLevel count], 3 , @"number of top level returns");
	id penApps=[[topLevel objectAtIndex:0] valueForKeyPath:@"value.array.data"];
	INTEXPECT( [penApps count], 5 , @"number of top level returns");
//	IDEXPECT([[[penApps objectAtIndex:4] objectForKey:@"struct"] objectAtIndex:3],@"bozo",@"bozo");
	id spanishDescription=[[[[penApps objectAtIndex:4] objectForKey:@"struct"] objectAtIndex:3] valueForKeyPath:@"value.string"];
//	IDEXPECT( [spanishDescription description], @"The American Heritage® Spanish Dictionary, Second Edition at your fingertips.", @"result");
	INTEXPECT( [parser dataEncoding], NSUTF8StringEncoding, @"UTF8 ?");
}

+(void)testNumericEntities
{
	NSData* xmldata=[self frameworkResource:@"numericEntities" category:@"xml"];
	MPWMAXParser *parser=[self parser];
	[parser setUndefinedTagAction:MAX_ACTION_PLIST];
	NSDictionary *result=[parser parsedData:xmldata];
	EXPECTNOTNIL( xmldata , @"source");
//	NSLog(@"result: %@",result);
	IDEXPECT( [result objectForKey:@"zero"], @"0" , @"hex ");
	IDEXPECT( [result objectForKey:@"one"], @"1" , @"decimal ");
}


+domForResource:(NSString*)resourceName category:(NSString*)resourceType
{
	id parser=[self domParser];
	id data=[self frameworkResource:resourceName category:resourceType];
	[parser parse:data];
	return [parser parseResult];
}

+(void)testEmptyXmlParse
{
	id dom = [self domForResource:@"test1" category:@"xml"];
	IDEXPECT( [dom name], @"xml" , @"name" );
	INTEXPECT( [dom count], 0 , @"number of children" );
}

+(void)testNestedXmlParse
{
	MPWXmlElement* dom = [self domForResource:@"test3" category:@"xml"];
	MPWXmlElement* child1,*child2;
	//	NSLog(@"dom result: %@",dom);
	IDEXPECT( [dom name], @"xml" , @"name" );
	INTEXPECT( [dom count], 2 , @"number of children" );
	child1=[dom childAtIndex:0];
	child2=[dom childAtIndex:1];
	IDEXPECT( [child1 name], @"nested1" , @"child1" );
	IDEXPECT( [child2 name], @"nested2" , @"child2" );
	INTEXPECT( [[dom childAtIndex:0] count], 1 , @"number of children" );
	IDEXPECT( [[dom childAtIndex:1] name], @"nested2" , @"child2" );
	INTEXPECT( [[dom childAtIndex:1] count], 1 , @"number of children" );
	IDEXPECT( [[dom childAtIndex:1] childAtIndex:0], @"content1" , @"/nested2/" );
}

+(void)testXmlWithAttributes
{
	MPWXmlElement* dom = [self domForResource:@"archiversample" category:@"xml"];
	IDEXPECT( [dom name] , @"MPWSubData", @"top level");
	IDEXPECT( [[dom childAtIndex:0] name], @"myData" , @"child 1" );
	INTEXPECT( [[[dom childAtIndex:0] attributes] count], 1 , @"1 attribute" );
	IDEXPECT( [(id <NSXMLAttributes>)[[dom childAtIndex:0] attributes] objectForKey:@"idref"], @"4" , @"idref value" );
	IDEXPECT( [(id <NSXMLAttributes>)[[dom childAtIndex:1] attributes] objectForKey:@"valuetype"], @"i" , @"valuetype" );
	
}

+(void)testDOMHasElementBytes
{
	MPWXmlElement* dom = [self domForResource:@"test3" category:@"xml"];
	MPWXmlElement* child1,*child2;
	child1=[dom childAtIndex:0];
	child2=[dom childAtIndex:1];
	IDEXPECT( [child1 elementBytes], @"<nested1>content</nested1>", @"total data of first child");
	IDEXPECT( [child2 elementBytes], @"<nested2>content1</nested2>", @"total data of second child");
}

+(void)testParseRestrictedByLevel
{
	id parser=[self domParser];
	id data=[self frameworkResource:@"nested" category:@"xml"];
	MPWXmlElement* dom;
	MPWXmlElement* child1,*child2;
	[parser setMaxDepthAllowed:1];
	[parser parse:data];
	dom = [parser parseResult];
	child1=[dom childAtIndex:0];
	child2=[dom childAtIndex:1];
	IDEXPECT( [child1 name], @"nested1" , @"child1" );
	INTEXPECT( [child1 count], 0 , @"children of first element should be invisible");
	NSAssert( [child1 isIncomplete], @"child1 does not have isIncomplete flag set (and should)");
	NSAssert( ![child2 isIncomplete], @"child1 has isIncomplete flag set (and should not)");
}

+(void)test16bitNestedXmlParse
{
	MPWXmlElement* dom = [self domForResource:@"test3_16bit" category:@"xml"];
	MPWXmlElement* child1,*child2;
	//	NSLog(@"dom result: %@",dom);
	IDEXPECT( [dom name], @"xml" , @"name" );
	INTEXPECT( [dom count], 2 , @"number of children" );
	child1=[dom childAtIndex:0];
	child2=[dom childAtIndex:1];
	IDEXPECT( [child1 name], @"nested1" , @"child1" );
	IDEXPECT( [child2 name], @"nested2" , @"child2" );
	INTEXPECT( [[dom childAtIndex:0] count], 1 , @"number of children" );
	IDEXPECT( [[dom childAtIndex:1] name], @"nested2" , @"child2" );
	INTEXPECT( [[dom childAtIndex:1] count], 1 , @"number of children" );
	IDEXPECT( [[dom childAtIndex:1] childAtIndex:0], @"content1" , @"/nested2/" );
}

+(void)testRewriteOfPlainDOM
{
	id parser=[self domParser];
	id xmlData=[self frameworkResource:@"nested" category:@"xml"];
	MPWXmlElement* dom;
	MPWXmlGeneratorStream *writer=[MPWXmlGeneratorStream stream];
	[parser parse:xmlData];
	dom=[parser parseResult];
	[writer writeObject:dom];
	IDEXPECT( [[[writer target] target] stringValue], [xmlData stringValue], @"rewritten data");
}

+(void)testRewriteOfLazyDOM
{
	MPWMAXParser* parser=[self domParser];
	id xmlData=[self frameworkResource:@"nested" category:@"xml"];
	MPWXmlElement* dom;
	MPWXmlGeneratorStream *writer=[MPWXmlGeneratorStream stream];
	[parser setMaxDepthAllowed:1];
	[parser parse:xmlData];
	dom=[parser parseResult];
	[writer writeObject:dom];
	IDEXPECT( [[[writer target] target] stringValue], [xmlData stringValue], @"rewritten data");
}

+(void)testUTF8Attributes
{
	MPWMAXParser* parser=[self domParser];
	id xmlData=[self frameworkResource:@"Faehre" category:@"xml"];
	id dom=nil;
	NSString *faehre;
	[parser parse:xmlData];
	dom=[parser parseResult];
	faehre=[[(MPWXmlElement*)[dom childAtIndex:0] attributes] objectForKey:@"Art"];
	INTEXPECT( [faehre characterAtIndex:1], 228, @"Umlaut in UTF-8");
	INTEXPECT( [faehre characterAtIndex:0], 'F', @"Umlaut in UTF-8");
}

+(void)testISO8859Attributes
{
	MPWMAXParser* parser=[self domParser];
	id xmlData=[self frameworkResource:@"Faehre-iso" category:@"xml"];
	id dom=nil;
	NSString *faehre;
	[parser parse:xmlData];
	dom=[parser parseResult];
	faehre=[[(MPWXmlElement*)[dom childAtIndex:0] attributes] objectForKey:@"Art"];
	INTEXPECT( [faehre characterAtIndex:1], 228, @"Umlaut in ISO-8859");
	INTEXPECT( [faehre characterAtIndex:0], 'F', @"Umlaut in ISO-8859");
}

+(void)testParsingNilReturnsNil
{
	EXPECTNIL( [[self parser] parsedData:nil], @"parsing nil should return nil");
}

+(void)testParseStatesDotXml
{
	id xmlData=[self frameworkResource:@"states" category:@"xml"];
	id parser = [self parser];
	[parser setUndefinedTagAction:MAX_ACTION_CHILDREN];
	id result = [parser parsedData:xmlData];
	EXPECTNOTNIL( result, @"should have parsed something");
}



+(void)testAttributeValuesInPlistParse
{
	id xmlData=[self frameworkResource:@"session" category:@"xml"];
	MPWMAXParser* parser = [self parser];
	NSDictionary* result = [parser parsedData:xmlData];
	NSDictionary* clip = [[result objectForKey:@"AudioList"] objectForKey:@"AudioClip"];
	IDEXPECT( [clip objectForKey:@"name"], @"audio-0.aac", @"clip name in attributes");
	IDEXPECT( [clip objectForKey:@"StartTime"], @"10948027575", @"StartTime in elements");
	IDEXPECT( [clip objectForKey:@"EndTime"], @"10950584119", @"EndTime in elements");
}

#if NS_BLOCKS_AVAILABLE

+(void)testSimpleInlineBlockParseAction
{
	id xmlData=[self frameworkResource:@"session" category:@"xml"];
	MPWMAXParser* parser = [self parser];
	NSString *tagToHandle=@"AudioList";
	[parser setHandler:parser forElements:[NSArray arrayWithObject:tagToHandle] inNamespace:nil prefix:@"" map:nil];
	[parser handleElement:tagToHandle withBlock:^(id elements,id attributes ,id parser){ 
		return [@"Parse result" retain];
	}];
	NSDictionary* result = [parser parsedData:xmlData];
	IDEXPECT( [result objectForKey:tagToHandle], @"Parse result", @"block return");
	
}

#endif
+testSelectors
{
	return [NSArray arrayWithObjects:
			@"testEmptyParseDoesntRaiseAndSetsDefaultEncoding",
			@"testISOEncodingSetByXML",
			@"testWindowsEncodingSetByXML",
			@"testXMLVersion",
			@"testParseUndeclaredElementsToPlist",
			@"testParseUndeclaredElementsToXMLAttributes",
			@"testParseElementsToXMLAttributesWithUniqueKeys",
			@"testParseElementsToXMLAttributesWithNamespaces",
			@"testRecoverFromISOEncodingClaimingUTF8ResultingInIllegalByteSequences",
		@"testNumericEntities",
			@"testEmptyXmlParse",
			@"testNestedXmlParse",
			@"testXmlWithAttributes",
			@"testDOMHasElementBytes",
			@"testParseRestrictedByLevel",
			@"test16bitNestedXmlParse",
			@"testRewriteOfPlainDOM",
			@"testRewriteOfLazyDOM",
			@"testUTF8Attributes",
			@"testISO8859Attributes",
			@"testParsingNilReturnsNil",
			@"testParseStatesDotXml",
			@"testAttributeValuesInPlistParse",
#if NS_BLOCKS_AVAILABLE
			@"testSimpleInlineBlockParseAction",
#endif
			nil];
}




@end
#endif

#ifndef RELEASE

@implementation NSXMLParser(MessageOrientedParsing)

-(void)_activateMAX
{
	if (!_reserved2 || ![_reserved2 isKindOfClass:[MPWMAXParser class]]) {
		_reserved2=[[MPWMAXParser alloc] init];
	}
}

+parser
{
	id parser=[[[self alloc] initWithData:[NSData data]] autorelease];
	[parser _activateMAX];
	return parser;
}

-(BOOL)reportIgnoreableWhitespace
{
	[self _activateMAX];
	return [_reserved2 reportIgnoreableWhitespace];
}

-(BOOL)enforceTagNesting
{
	[self _activateMAX];
	return [_reserved2 enforceTagNesting];
}

-(BOOL)ignoreCase
{
	[self _activateMAX];
	return [_reserved2 ignoreCase];
}

-(void)setReportIgnoreableWhitespace:(BOOL)flag
{
	[self _activateMAX];
	[_reserved2 setReportIgnoreableWhitespace:flag];
}

-(void)setIgnoreCase:(BOOL)flag
{
	[self _activateMAX];
	[_reserved2 setIgnoreCase:flag];
}

-(void)setEnforceTagNesting:(BOOL)flag
{
	[self _activateMAX];
	[_reserved2 setEnforceTagNesting:flag];
}

-(BOOL)parse:(NSData*)data
{
	[self _activateMAX];
	return [_reserved2 parse:data];
}

-(NSInteger)currentElementNestingLevel
{
	[self _activateMAX];
	return [_reserved2 currentElementNestingLevel];
}

-(NSString*)elementNameAtNestingLevel:(NSInteger)depth
{
	[self _activateMAX];
	return [_reserved2 elementNameAtNestingLevel:depth];
}


-(id <NSXMLAttributes>)elementAttributesAtNestingLevel:(NSInteger)depth
{
	[self _activateMAX];
	return [_reserved2 elementAttributesAtNestingLevel:depth];
}

-(id)parseResult
{
	[self _activateMAX];
	return [_reserved2 parseResult];
}



-(void)setHandler:(id)handler forElements:(NSArray*)elementNames inNamespace:(NSString*)namespaceString
							   prefix:(NSString*)prefix map:(NSDictionary*)map 
{
	[self _activateMAX];
	[_reserved2 setHandler:handler forElements:elementNames inNamespace:namespaceString
							   prefix:prefix map:map ];
}							   


-(void)setHandler:(id)handler forTags:(NSArray*)tagNamespace inNamespace:(NSString*)namespaceString 
						       prefix:(NSString*)prefix map:(NSDictionary*)map
{
	[self _activateMAX];
	[_reserved2 setHandler:handler forTags:tagNamespace inNamespace:namespaceString 
						       prefix:prefix map:map];
}							   


-(void)declareAttributes:(NSArray*)attributes inNamespace:(NSString*)namespaceString 
{
	[self _activateMAX];
	[_reserved2 declareAttributes:attributes inNamespace:namespaceString ];
}




@end

#endif


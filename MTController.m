#include "MTController.h"
#include "MTRowView.h"
#include "MTScratchpad.h"
#import "VT100.h"

@interface UIKeyboardImpl
+(id)sharedInstance;
-(BOOL)isShifted;
-(BOOL)isShiftLocked;
-(void)setShift:(BOOL)shift;
@end

@interface UIApplication (Private)
-(void)suspend;
@end

static BOOL scanRGB(NSString* vstr,unsigned int* cv) {
  return ([vstr isKindOfClass:[NSString class]]
   && [[NSScanner scannerWithString:vstr] scanHexInt:cv])?
   (*cv&=0xffffff,YES):NO;
}
static CGColorRef createColor(CGColorSpaceRef cspace,unsigned int cv) {
  return CGColorCreate(cspace,(CGFloat[]){
   (CGFloat)((cv>>16)&0xff)/0xff,(CGFloat)((cv>>8)&0xff)/0xff,
   (CGFloat)(cv&0xff)/0xff,1});
}
static void cacheColor(CFMutableBagRef bag,CGColorRef* var,CGColorRef color) {
  CFTypeRef prev=*var;
  if(color!=prev){
    CFBagAddValue(bag,color);
    *var=(void*)CFBagGetValue(bag,color);
    if(prev){CFBagRemoveValue(bag,prev);}
  }
  CFRelease(color);
}
static CGSize getScreenSize(UIScrollView* view) {
  CGSize size=view.bounds.size;
  UIEdgeInsets inset=view.contentInset;
  size.height-=inset.top+inset.bottom;
  return size;
}
static enum {
  kTapZoneTopLeft,
  kTapZoneTop,
  kTapZoneTopRight,
  kTapZoneLeft,
  kTapZoneCenter,
  kTapZoneRight,
  kTapZoneBottomLeft,
  kTapZoneBottom,
  kTapZoneBottomRight,
} getTapZone(UIGestureRecognizer* gesture,CGPoint* optr) {
  UIScrollView* view=(UIScrollView*)gesture.view;
  CGPoint origin=[gesture locationInView:view];
  if(optr){*optr=origin;}
  CGPoint offset=view.contentOffset;
  origin.x-=offset.x;
  origin.y-=offset.y;
  CGSize size=getScreenSize(view);
  CGFloat margin=(size.width<size.height?size.width:size.height)/5;
  if(margin<60){margin=60;}
  BOOL right=(origin.x>size.width-margin);
  return (origin.y<margin)?right?kTapZoneTopRight:
   (origin.x<margin)?kTapZoneTopLeft:kTapZoneTop:
   (origin.y>size.height-margin)?right?kTapZoneBottomRight:
   (origin.x<margin)?kTapZoneBottomLeft:kTapZoneBottom:
   right?kTapZoneRight:(origin.x<margin)?kTapZoneLeft:kTapZoneCenter;
}
static NSString* getTitle(VT100* terminal) {
  CFStringRef title=terminal.title;
  if(title){return (NSString*)title;}
  title=[terminal copyProcessName];
  NSString* tstr=(title && CFStringGetLength(title))?
   [NSString stringWithFormat:@"<%@>",title]:@"---";
  if(title){CFRelease(title);}
  return tstr;
}

@interface MTRespondingTableView : UITableView @end
@implementation MTRespondingTableView
-(BOOL)canBecomeFirstResponder {return YES;}
@end

@implementation MTController
-(id)init {
  if((self=[super init])){
    // set up color table
    colorBag=CFBagCreateMutable(NULL,0,&kCFTypeBagCallBacks);
    colorSpace=CGColorSpaceCreateDeviceRGB();
    nullColor=CGColorCreate(colorSpace,(CGFloat[]){0,0,0,0});
    const CGFloat cvfloat[6]={0,(CGFloat)0x5f/0xff,
     (CGFloat)0x87/0xff,(CGFloat)0xaf/0xff,(CGFloat)0xd7/0xff,1};
    unsigned int i,j,k,z=16;
    CGFloat RGBA[4];
    RGBA[3]=1;
    for (i=0;i<6;i++){
      RGBA[0]=cvfloat[i];
      for (j=0;j<6;j++){
        RGBA[1]=cvfloat[j];
        for (k=0;k<6;k++){
          RGBA[2]=cvfloat[k];
          CGColorRef color=CGColorCreate(colorSpace,RGBA);
          CFBagAddValue(colorBag,colorTable[z++]=color);
          CFRelease(color);
        }
      }
    }
    for (i=0;i<24;i++){
      unsigned int cv=i*10+8;
      CGFloat c=(CGFloat)cv/0xff;
      CGColorRef color=CGColorCreate(colorSpace,(CGFloat[]){c,c,c,1});
      CFBagAddValue(colorBag,colorTable[z++]=color);
      CFRelease(color);
    }
    // set up text decoration attributes
    ctUnderlineStyleSingle=CFNumberCreate(NULL,
     kCFNumberIntType,(const int[]){kCTUnderlineStyleSingle});
    ctUnderlineStyleDouble=CFNumberCreate(NULL,
     kCFNumberIntType,(const int[]){kCTUnderlineStyleDouble});
    // set up bell sound
    CFURLRef soundURL=CFBundleCopyResourceURL(CFBundleGetMainBundle(),
     CFSTR("bell"),CFSTR("caf"),NULL);
    if(soundURL){
      bellSound=AudioServicesCreateSystemSoundID(soundURL,
       &bellSoundID)==kAudioServicesNoError;
      CFRelease(soundURL);
    }
    // set up display
    screenSection=[[NSIndexSet alloc] initWithIndex:0];
    allTerminals=[[NSMutableArray alloc] init];
  }
  return self;
}
-(BOOL)handleOpenURL:(NSURL*)URL {
  NSUserDefaults* defaults=[NSUserDefaults standardUserDefaults];
  NSString* name=[NSBundle mainBundle].bundleIdentifier;
  NSDictionary* settings=[defaults persistentDomainForName:name];
  struct {
    struct keyvalue {
      NSString* key;
      id value;
    } palette,bgDefault,fgDefault,fgBold,bgCursor,fgCursor,
      fontName,fontSize,fontWidthSample,fontProportional;
  } prefs={
    .palette={.key=@"palette"},
    .bgDefault={.key=@"bgColor"},
    .fgDefault={.key=@"fgColor"},
    .fgBold={.key=@"fgBoldColor"},
    .bgCursor={.key=@"bgCursorColor"},
    .fgCursor={.key=@"fgCursorColor"},
    .fontName={.key=@"fontName"},
    .fontSize={.key=@"fontSize"},
    .fontWidthSample={.key=@"fontWidthSample"},
    .fontProportional={.key=@"fontProportional"},
  };
  struct keyvalue* preflist=(void*)&prefs;
  const int nprefs=sizeof(prefs)/sizeof(struct keyvalue);
  if(URL){
    for (NSString* kvstr in [URL.query componentsSeparatedByString:@"&"]){
      NSUInteger pos=[kvstr rangeOfString:@"="].location;
      if(pos==NSNotFound || pos==0){continue;}
      NSString* key=[kvstr substringToIndex:pos];
      int i;
      for (i=0;i<nprefs;i++){
        struct keyvalue* kv=&preflist[i];
        if(![key isEqualToString:kv->key]){continue;}
        if(pos==kvstr.length-1){kv->value=(id)kCFNull;}
        else {
          void* ptr=(void*)kv;
          NSString* vstr=[[kvstr substringFromIndex:pos+1]
           stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
          kv->value=(ptr==&prefs.palette)?[vstr componentsSeparatedByString:@","]:
           (ptr==&prefs.fontSize)?[NSNumber numberWithDouble:vstr.doubleValue]:
           (ptr==&prefs.fontProportional)?vstr.intValue?
           (id)kCFBooleanTrue:(id)kCFNull:vstr;
        }
        break;
      }
    }
    NSMutableDictionary* msettings=[NSMutableDictionary
     dictionaryWithCapacity:nprefs];
    BOOL keep=(URL.path==nil);
    int i;
    for (i=0;i<nprefs;i++){
      struct keyvalue* kv=&preflist[i];
      NSString* key=kv->key;
      if(!kv->value){
        id value=[settings objectForKey:key];
        if(keep || !value){
          kv->key=nil;
          if(keep){kv->value=value;}
        }
      }
      else if(kv->value==(id)kCFNull){kv->value=nil;}
      if(kv->value){[msettings setObject:kv->value forKey:key];}
    }
    if(msettings.count){[defaults setPersistentDomain:msettings forName:name];}
    else {[defaults removePersistentDomainForName:name];}
  }
  else {
    int i;
    for (i=0;i<nprefs;i++){
      struct keyvalue* kv=&preflist[i];
      kv->value=[settings objectForKey:kv->key];
    }  
  }
  unsigned int cv;
  if(prefs.palette.key){
    const unsigned int xterm16[]={
     0x000000,0xaa0000,0x00aa00,0xaa5500,0x0000aa,0xaa00aa,0x00aaaa,0xaaaaaa,
     0x555555,0xff5555,0x55ff55,0xffff55,0x5555ff,0xff55ff,0x55ffff,0xffffff};
    NSArray* palette=prefs.palette.value;
    NSUInteger count=[palette isKindOfClass:[NSArray class]]?palette.count:0;
    unsigned int i;
    for (i=0;i<16;i++){
      cacheColor(colorBag,&colorTable[i],createColor(colorSpace,
       (i<count && scanRGB([palette objectAtIndex:i],&cv))?cv:xterm16[i]));
    }
  }
  BOOL chgbg=NO;
  if(prefs.bgDefault.key){
    cacheColor(colorBag,&bgDefault,createColor(colorSpace,
     scanRGB(prefs.bgDefault.value,&cv)?cv:0x000000));
    prefs.fgCursor.key=prefs.bgDefault.key;
    // convert RGB to YIQ, presume dark background if luma<50%
    const CGFloat* bgRGB=CGColorGetComponents(bgDefault);
    BOOL _darkBG=(bgRGB[0]*0.299+bgRGB[1]*0.587+bgRGB[2]*0.114)<0.5;
    if(darkBG!=_darkBG){
      darkBG=_darkBG;
      chgbg=YES;
    }
  }
  if(chgbg || prefs.fgDefault.key){
    cacheColor(colorBag,&fgDefault,createColor(colorSpace,
     scanRGB(prefs.fgDefault.value,&cv)?cv:darkBG?0xaaaaaa:0x000000));
    prefs.bgCursor.key=prefs.fgDefault.key;
  }
  if(chgbg || prefs.fgBold.key){
    cacheColor(colorBag,&fgBold,createColor(colorSpace,
     scanRGB(prefs.fgBold.value,&cv)?cv:darkBG?0xffffff:0x000000));
  }
  if(prefs.bgCursor.key){
    cacheColor(colorBag,&bgCursor,scanRGB(prefs.bgCursor.value,&cv)?
     createColor(colorSpace,cv):CGColorRetain(fgDefault));
  }
  if(prefs.fgCursor.key){
    cacheColor(colorBag,&fgCursor,scanRGB(prefs.fgCursor.value,&cv)?
     createColor(colorSpace,cv):CGColorRetain(bgDefault));
  }
  BOOL chgfont=(prefs.fontName.key || prefs.fontSize.key
   || prefs.fontProportional.key);
  if(chgfont){
    if(ctFont){
      CFRelease(ctFont);
      CFRelease(ctFontBold);
      CFRelease(ctFontItalic);
      CFRelease(ctFontBoldItalic);
    }
    NSString* fname=prefs.fontName.value;
    NSNumber* fsize=prefs.fontSize.value;
    ctFont=CTFontCreateWithName(([fname isKindOfClass:[NSString class]]
     && fname.length)?(CFStringRef)fname:CFSTR("Courier"),
     ([fsize isKindOfClass:[NSNumber class]]?fsize.doubleValue:0)?:10,NULL);
  }
  if(chgfont || prefs.fontWidthSample.key){
    NSString* sample=prefs.fontWidthSample.value;
    NSUInteger sslength;
    CFDictionaryRef ssattr=CFDictionaryCreate(NULL,
     (const void**)&kCTFontAttributeName,(const void**)&ctFont,1,NULL,NULL);
    CFAttributedStringRef ssobj=CFAttributedStringCreate(NULL,
     ([sample isKindOfClass:[NSString class]] && (sslength=sample.length))?
     (CFStringRef)sample:(sslength=1,CFSTR("$")),ssattr);
    CTLineRef ssline=CTLineCreateWithAttributedString(ssobj);
    CGFloat ascent,descent,leading;
    colWidth=CTLineGetTypographicBounds(ssline,
     &ascent,&descent,&leading)/sslength;
    rowHeight=ascent+descent+leading;
    CFRelease(ssline);
    CFRelease(ssobj);
    CFRelease(ssattr);
  }
  if(chgfont){
    NSNumber* isprop=prefs.fontProportional.value;
    if(![isprop isKindOfClass:[NSNumber class]] || !isprop.boolValue){
      // turn off all optional ligatures
      const int values[]={kCommonLigaturesOffSelector,kRareLigaturesOffSelector,
       kLogosOffSelector,kRebusPicturesOffSelector,kDiphthongLigaturesOffSelector,
       kSquaredLigaturesOffSelector,kAbbrevSquaredLigaturesOffSelector,
       kSymbolLigaturesOffSelector,kContextualLigaturesOffSelector,
       kHistoricalLigaturesOffSelector};
      const size_t nvalues=sizeof(values)/sizeof(int);
      CFNumberRef ligkey=CFNumberCreate(NULL,kCFNumberIntType,(const int[]){kLigaturesType});
      CFMutableArrayRef ffsettings=CFArrayCreateMutable(NULL,nvalues,&kCFTypeArrayCallBacks);
      unsigned int i;
      for (i=0;i<nvalues;i++){
        CFNumberRef ligvalue=CFNumberCreate(NULL,kCFNumberIntType,&values[i]);
        CFDictionaryRef ligsetting=CFDictionaryCreate(NULL,
         (const void*[]){kCTFontFeatureTypeIdentifierKey,kCTFontFeatureSelectorIdentifierKey},
         (const void*[]){ligkey,ligvalue},2,NULL,&kCFTypeDictionaryValueCallBacks);
        CFRelease(ligvalue);
        CFArrayAppendValue(ffsettings,ligsetting);
        CFRelease(ligsetting);
      }
      CFRelease(ligkey);
      // set fixed advance
      CFNumberRef advance=CFNumberCreate(NULL,kCFNumberCGFloatType,&colWidth);
      CFDictionaryRef attrdict=CFDictionaryCreate(NULL,
       (const void*[]){kCTFontFixedAdvanceAttribute,kCTFontFeatureSettingsAttribute},
       (const void*[]){advance,ffsettings},2,NULL,&kCFTypeDictionaryValueCallBacks);
      CFRelease(advance);
      CFRelease(ffsettings);
      CTFontDescriptorRef desc=CTFontDescriptorCreateWithAttributes(attrdict);
      CFRelease(attrdict);
      // try to derive a new font
      CTFontRef font=CTFontCreateCopyWithAttributes(ctFont,0,NULL,desc);
      CFRelease(desc);
      if(font){
        CFRelease(ctFont);
        ctFont=font;
      }
    }
    CTFontSymbolicTraits traits=CTFontGetSymbolicTraits(ctFont)
     ^kCTFontBoldTrait^kCTFontItalicTrait;
    ctFontBold=CTFontCreateCopyWithSymbolicTraits(ctFont,0,NULL,
     traits,kCTFontBoldTrait)?:CFRetain(ctFont);
    ctFontItalic=CTFontCreateCopyWithSymbolicTraits(ctFont,0,NULL,
     traits,kCTFontItalicTrait)?:CFRetain(ctFont);
    ctFontBoldItalic=CTFontCreateCopyWithSymbolicTraits(ctFont,0,NULL,
     traits,kCTFontBoldTrait^kCTFontItalicTrait)?:CFRetain(ctFont);
  }
  UITableView* tableView=(UITableView*)self.view;
  tableView.backgroundColor=[UIColor colorWithCGColor:bgDefault];
  tableView.indicatorStyle=darkBG?
   UIScrollViewIndicatorStyleWhite:UIScrollViewIndicatorStyleBlack;
  tableView.rowHeight=rowHeight;
  if(URL){
    if(chgbg){
      [self resignFirstResponder];
      [self becomeFirstResponder];
    }
    else {[self screenSizeDidChange];}
  }
  return YES;
}
-(BOOL)isRunning {
  for (VT100* terminal in allTerminals){
    if(terminal.isRunning){return YES;}
  }
  return NO;
}
-(void)screenSizeDidChange {
  UITableView* tableView=(UITableView*)self.view;
  CGSize size=getScreenSize(tableView);
  CFIndex width=size.width/colWidth;
  CFIndex height=size.height/rowHeight;
  if(activeTerminal){[activeTerminal setWidth:width height:height];}
  else {
    VT100* terminal=[[VT100 alloc] initWithWidth:width height:height];
    terminal.delegate=self;
    terminal.encoding=kCFStringEncodingUTF8;
    [allTerminals insertObject:terminal atIndex:activeIndex];
    [activeTerminal=terminal release];
  }
  if(previousIndex==activeIndex){
    [self terminal:activeTerminal changed:NULL
     deleted:NULL inserted:NULL bell:NO];
  }
  else {  
    CGRect frame=tableView.frame,endFrame=frame;
    endFrame.origin.x=frame.size.width;
    if(previousIndex==NSNotFound || previousIndex<activeIndex)
      endFrame.origin.x*=-1;
    previousIndex=activeIndex;
    [UIView animateWithDuration:0.25
     animations:^{tableView.frame=endFrame;}
     completion:^(BOOL finished){
      tableView.frame=frame;
      [self terminal:activeTerminal changed:NULL
       deleted:NULL inserted:NULL bell:NO];
    }];
  }
}
-(void)closeWindow {
  [allTerminals removeObjectAtIndex:activeIndex];
  NSUInteger count=allTerminals.count;
  if(count==0){[[UIApplication sharedApplication] suspend];}
  else {
    if(activeIndex==count){activeIndex--;}
    else {previousIndex=NSNotFound;}
    activeTerminal=[allTerminals objectAtIndex:activeIndex];
    [self screenSizeDidChange];
  }
}
-(void)actionSheet:(UIActionSheet*)sheet clickedButtonAtIndex:(NSInteger)index {
  if(index==sheet.destructiveButtonIndex){[self closeWindow];}
  else if(index!=sheet.cancelButtonIndex){
    activeIndex=index;
    activeTerminal=(index<allTerminals.count)?
     [allTerminals objectAtIndex:index]:nil;
    [self screenSizeDidChange];
  }
}
-(BOOL)canBecomeFirstResponder {
  return YES;
}
-(UIKeyboardAppearance)keyboardAppearance {
  return darkBG?UIKeyboardAppearanceDark:UIKeyboardAppearanceDefault;
}
-(UITextAutocapitalizationType)autocapitalizationType {
  return UITextAutocapitalizationTypeNone;
}
-(UITextAutocorrectionType)autocorrectionType {
  return UITextAutocorrectionTypeNo;
}
-(BOOL)isSecureTextEntry {
  return YES;// disable dictation
}
-(UITextRange*)selectedTextRange {
  return nil;// disable the native arrow keys
}
-(BOOL)hasText {
  return YES;// always enable the backspace key
}
-(void)deleteBackward {
  [activeTerminal sendKey:kVT100KeyBackArrow];
  if(!ctrlLock){
    [[UIMenuController sharedMenuController]
     setMenuVisible:NO animated:YES];
  }
}
-(void)insertText:(NSString*)text {
  if(text.length==1){
    unichar c=[text characterAtIndex:0];
    if(c<0x80){
      [activeTerminal sendKey:((c==0x20 || c>=0x40)
       && [UIMenuController sharedMenuController].menuVisible)?c&0x1f:c];
      text=nil;
    }
  }
  if(text){[activeTerminal sendString:(CFStringRef)text];}
  if(!ctrlLock){
    [[UIMenuController sharedMenuController]
     setMenuVisible:NO animated:YES];
  }
}
-(NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 1;
}
-(NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return activeTerminal.numberOfLines;
}
-(UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)ipath {
  UITableViewCell* cell=[tableView dequeueReusableCellWithIdentifier:@"Cell"];
  MTRowView* rowView;
  if(cell){rowView=(MTRowView*)cell.backgroundView;}
  else {
    cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
     reuseIdentifier:@"Cell"] autorelease];
    cell.backgroundView=rowView=[[[MTRowView alloc] init] autorelease];
  }
  CFIndex length,cursorColumn;
  screen_char_t* ptr=[activeTerminal charactersAtLineIndex:ipath.row
   length:&length cursorColumn:&cursorColumn];
  if(ptr){
    unichar* ucbuf=malloc(length*sizeof(unichar));
    CFIndex i;
    for (i=0;i<length;i++){ucbuf[i]=ptr[i].c?:' ';}
    CFStringRef ucstr=CFStringCreateWithCharactersNoCopy(NULL,ucbuf,length,kCFAllocatorMalloc);
    CFMutableAttributedStringRef string=CFAttributedStringCreateMutable(NULL,length);
    CFAttributedStringBeginEditing(string);
    CFAttributedStringReplaceString(string,CFRangeMake(0,0),ucstr);
    CFRelease(ucstr);// will automatically free(ucbuf)
    CTFontRef fontface=NULL;
    CGColorRef bgcolor=NULL,fgcolor=NULL,stcolor=NULL,ulcolor=NULL;
    CFNumberRef ulstyle=NULL;
    CFIndex ffspan=0,bgcspan=0,fgcspan=0,stcspan=0,ulcspan=0,ulsspan=0;
    for (i=0;i<=length;i++,ptr++){
      CTFontRef ff;
      CGColorRef bgc,fgc,stc,ulc;
      CFNumberRef uls;
      if(i==length){
        ff=NULL;
        bgc=fgc=stc=ulc=NULL;
        uls=NULL;
      }
      else {
        BOOL bold=ptr->weight==kFontWeightBold;
        ff=bold?ptr->italicize?ctFontBoldItalic:ctFontBold:
         ptr->italicize?ctFontItalic:ctFont;
        if(i==cursorColumn){
          bgc=bgCursor;
          fgc=fgCursor;
        }
        else {
          bgc=ptr->bgcolor_isset?colorTable[ptr->bgcolor]:bgDefault;
          fgc=ptr->fgcolor_isset?colorTable[(bold && ptr->fgcolor<8)?
           ptr->fgcolor+8:ptr->fgcolor]:bold?fgBold:fgDefault;
          if(ptr->inverse){
            CGColorRef _fgc=fgc;
            fgc=bgc;
            bgc=_fgc;
          }
        }
        stc=(ptr->strikethrough && fgc!=bgc)?fgc:NULL;
        switch(ptr->underline){
          case kUnderlineSingle:
            ulc=fgc;
            uls=ctUnderlineStyleSingle;
            break;
          case kUnderlineDouble:
            ulc=fgc;
            uls=ctUnderlineStyleDouble;
            break;
          default:
            ulc=NULL;
            uls=NULL;
            break;
        }
        if(ptr->hidden){fgc=nullColor;}
        if(bgc==bgDefault){bgc=NULL;}
      }
      if(fontface==ff){ffspan++;}
      else {
        if(fontface) CFAttributedStringSetAttribute(
         string,CFRangeMake(i-ffspan,ffspan),
         kCTFontAttributeName,fontface);
        fontface=ff;
        ffspan=1;
      }
      if(bgcolor==bgc){bgcspan++;}
      else {
        if(bgcolor) CFAttributedStringSetAttribute(
         string,CFRangeMake(i-bgcspan,bgcspan),
         kMTBackgroundColorAttributeName,bgcolor);
        bgcolor=bgc;
        bgcspan=1;
      }
      if(fgcolor==fgc){fgcspan++;}
      else {
        if(fgcolor) CFAttributedStringSetAttribute(
         string,CFRangeMake(i-fgcspan,fgcspan),
         kCTForegroundColorAttributeName,fgcolor);
        fgcolor=fgc;
        fgcspan=1;
      }
      if(stcolor==stc){stcspan++;}
      else {
        if(stcolor) CFAttributedStringSetAttribute(
         string,CFRangeMake(i-stcspan,stcspan),
         kMTStrikethroughColorAttributeName,stcolor);
        stcolor=stc;
        stcspan=1;
      }
      if(ulcolor==stc){ulcspan++;}
      else {
        if(ulcolor) CFAttributedStringSetAttribute(
         string,CFRangeMake(i-ulcspan,ulcspan),
         kCTUnderlineColorAttributeName,ulcolor);
        ulcolor=ulc;
        ulcspan=1;
      }
      if(ulstyle==uls){ulsspan++;}
      else {
        if(ulstyle) CFAttributedStringSetAttribute(
         string,CFRangeMake(i-ulsspan,ulsspan),
         kCTUnderlineStyleAttributeName,ulstyle);
        ulstyle=uls;
        ulsspan=1;
      }
    }
    CFAttributedStringEndEditing(string);
    [rowView renderString:string withBGColor:bgDefault];
    CFRelease(string);
  }
  return cell;
}
-(void)handleKeyboardGesture:(UIGestureRecognizer*)gesture {
  if(gesture.state==UIGestureRecognizerStateBegan)
    [self.isFirstResponder?self.view:self becomeFirstResponder];
}
-(void)handleSwipeGesture:(UISwipeGestureRecognizer*)gesture {
  switch(gesture.direction){
    case UISwipeGestureRecognizerDirectionRight:
      if(activeIndex==0){return;}
      activeIndex--;
      break;
    case UISwipeGestureRecognizerDirectionLeft:
      if(activeIndex==allTerminals.count-1){return;}
      activeIndex++;
      break;
    default:return;
  }
  activeTerminal=[allTerminals objectAtIndex:activeIndex];
  [self screenSizeDidChange];
}
-(void)handleTapGesture:(UIGestureRecognizer*)gesture {
  if(!activeTerminal){return;}
  [[UIMenuController sharedMenuController] setMenuVisible:NO animated:YES];
  UIKeyboardImpl* keyboard=[UIKeyboardImpl sharedInstance];
  BOOL shift=keyboard.isShifted;
  VT100Key key;
  switch(getTapZone(gesture,NULL)){
    case kTapZoneTop:key=shift?kVT100KeyPageUp:kVT100KeyUpArrow;break;
    case kTapZoneBottom:key=shift?kVT100KeyPageDown:kVT100KeyDownArrow;break;
    case kTapZoneLeft:key=shift?kVT100KeyHome:kVT100KeyLeftArrow;break;
    case kTapZoneRight:key=shift?kVT100KeyEnd:kVT100KeyRightArrow;break;
    case kTapZoneTopLeft:key=kVT100KeyInsert;break;
    case kTapZoneTopRight:key=kVT100KeyDelete;break;
    case kTapZoneBottomLeft:key=kVT100KeyEsc;break;
    case kTapZoneBottomRight:key=kVT100KeyTab;break;
    default:return;
  }
  [activeTerminal sendKey:key];
  if(shift && !keyboard.isShiftLocked){[keyboard setShift:NO];}
}
-(void)handleHoldGesture:(UIGestureRecognizer*)gesture {
  if(!activeTerminal){return;}
  if(gesture.state==UIGestureRecognizerStateBegan){
    if(repeatTimer){return;}
    UIMenuController* menu=[UIMenuController sharedMenuController];
    [menu setMenuVisible:NO animated:YES];
    VT100Key key;
    CGPoint origin;
    switch(getTapZone(gesture,&origin)){
      case kTapZoneTop:key=kVT100KeyUpArrow;break;
      case kTapZoneBottom:key=kVT100KeyDownArrow;break;
      case kTapZoneLeft:key=kVT100KeyLeftArrow;break;
      case kTapZoneRight:key=kVT100KeyRightArrow;break;
      case kTapZoneTopRight:
        if(activeTerminal.isRunning){
          UIActionSheet* sheet=[[UIActionSheet alloc]
           initWithTitle:nil delegate:self cancelButtonTitle:@"Cancel"
           destructiveButtonTitle:@"Force Quit" otherButtonTitles:nil];
          [sheet showInView:gesture.view];
          [sheet release];
        }
        else {[self closeWindow];}
        return;
      case kTapZoneBottomRight:{
        UIActionSheet* sheet=[[UIActionSheet alloc]
         initWithTitle:nil delegate:self cancelButtonTitle:nil
         destructiveButtonTitle:nil otherButtonTitles:nil];
        for (VT100* terminal in allTerminals){
          [sheet addButtonWithTitle:[NSString stringWithFormat:@"%@%d: %@",
           (terminal==activeTerminal)?@"\u2713 ":
           terminal.bellDeferred?@"\u2407 ":@"",
           terminal.processID,getTitle(terminal)]];
        }
        [sheet addButtonWithTitle:@"(+)"];
        sheet.cancelButtonIndex=[sheet addButtonWithTitle:@"Cancel"];
        [sheet showInView:gesture.view];
        [sheet release];
        return;
      }
      case kTapZoneCenter:
        ctrlLock=NO;
        [menu setTargetRect:(CGRect){.origin=origin} inView:gesture.view];
        [menu setMenuVisible:YES animated:YES];
      default:return;
    }
    repeatTimer=[[NSTimer scheduledTimerWithTimeInterval:0.1
     target:self selector:@selector(repeatTimerFired:)
     userInfo:[NSNumber numberWithInt:key] repeats:YES] retain];
  }
  else if(gesture.state==UIGestureRecognizerStateEnded){
    if(!repeatTimer){return;}
    [repeatTimer invalidate];
    [repeatTimer release];
    repeatTimer=nil;
  }
}
-(void)repeatTimerFired:(NSTimer*)timer {
  [activeTerminal sendKey:[timer.userInfo intValue]];
}
-(BOOL)canPerformAction:(SEL)action withSender:(UIMenuController*)menu {
  if(!self.isFirstResponder){// keyboard is hidden
    if(!self.view.isFirstResponder){return NO;}
  }
  else if(action==@selector(ctrlLock:)){return !ctrlLock;}
  if(action==@selector(paste:)){
    return [[UIPasteboard generalPasteboard]
     containsPasteboardTypes:UIPasteboardTypeListString];
  }
  return action==@selector(reflow:);
}
-(void)paste:(UIMenuController*)menu {
  [activeTerminal sendString:(CFStringRef)[UIPasteboard generalPasteboard].string];
}
-(void)reflow:(UIMenuController*)menu {
  NSMutableString* text=[NSMutableString string];
  CFIndex count=activeTerminal.numberOfLines,i,blankspan=0;
  for (i=0;i<count;i++){
    CFIndex length,j;
    screen_char_t* ptr=[activeTerminal
     charactersAtLineIndex:i length:&length cursorColumn:NULL];
    while(length && !ptr[length-1].c){length--;}
    if(i && !ptr->wrapped){
      [text appendString:@"\n"];
      if(!length){blankspan++;}
    }
    if(length){
      blankspan=0;
      unichar* ucbuf=malloc(length*sizeof(unichar));
      for (j=0;j<length;j++){ucbuf[j]=ptr[j].c?:0xA0;}
      CFStringRef ucstr=CFStringCreateWithCharactersNoCopy(NULL,ucbuf,length,kCFAllocatorMalloc);
      [text appendString:(NSString*)ucstr];
      CFRelease(ucstr);// will automatically free(ucbuf)
    }
  }
  if(blankspan){
    NSUInteger length=text.length;
    [text deleteCharactersInRange:NSMakeRange(length-blankspan,blankspan)];
  }
  MTScratchpad* scratch=[[MTScratchpad alloc]
   initWithText:text fontSize:CTFontGetSize(ctFont) darkBG:darkBG];
  scratch.title=getTitle(activeTerminal);
  UINavigationController* nav=[[UINavigationController alloc]
   initWithRootViewController:scratch];
  [scratch release];
  nav.navigationBar.barStyle=darkBG?UIBarStyleBlack:UIBarStyleDefault;
  [self presentModalViewController:nav animated:YES];
  [nav release];
}
-(void)ctrlLock:(UIMenuController*)menu {
  ctrlLock=menu.menuVisible=YES;
  [menu update];
}
-(void)loadView {
  UITableView* tableView=[[MTRespondingTableView alloc]
   initWithFrame:CGRectZero style:UITableViewStylePlain];
  tableView.allowsSelection=NO;
  tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
  tableView.dataSource=self;
  // install gesture recognizers
  UILongPressGestureRecognizer* kbGesture=[[UILongPressGestureRecognizer alloc]
   initWithTarget:self action:@selector(handleKeyboardGesture:)];
  kbGesture.numberOfTouchesRequired=2;
  [tableView addGestureRecognizer:kbGesture];
  [kbGesture release];
  UISwipeGestureRecognizer* swipeGesture;
  swipeGesture=[[UISwipeGestureRecognizer alloc]
   initWithTarget:self action:@selector(handleSwipeGesture:)];
  swipeGesture.direction=UISwipeGestureRecognizerDirectionLeft;
  [tableView addGestureRecognizer:swipeGesture];
  [swipeGesture release];
  swipeGesture=[[UISwipeGestureRecognizer alloc]
   initWithTarget:self action:@selector(handleSwipeGesture:)];
  swipeGesture.direction=UISwipeGestureRecognizerDirectionRight;
  [tableView addGestureRecognizer:swipeGesture];
  [swipeGesture release];
  UITapGestureRecognizer* tapGesture=[[UITapGestureRecognizer alloc]
   initWithTarget:self action:@selector(handleTapGesture:)];
  [tableView addGestureRecognizer:tapGesture];
  [tapGesture release];
  UILongPressGestureRecognizer* holdGesture=[[UILongPressGestureRecognizer alloc]
   initWithTarget:self action:@selector(handleHoldGesture:)];
  holdGesture.minimumPressDuration=0.25;
  [tableView addGestureRecognizer:holdGesture];
  [holdGesture release];
  [self.view=tableView release];
  [self handleOpenURL:nil];
  // add custom menu items
  UIMenuItem* reflowitem=[[UIMenuItem alloc]
   initWithTitle:@"\u2630" action:@selector(reflow:)];
  UIMenuItem* ctrlitem=[[UIMenuItem alloc]
   initWithTitle:@"Ctrl Lock" action:@selector(ctrlLock:)];
  [UIMenuController sharedMenuController].menuItems=[NSArray
   arrayWithObjects:reflowitem,ctrlitem,nil];
  [reflowitem release];
  [ctrlitem release];
}
-(BOOL)terminalShouldReportChanges:(VT100*)terminal {
  return terminal==activeTerminal;
}
-(void)terminal:(VT100*)terminal changed:(CFSetRef)changes deleted:(CFSetRef)deletions inserted:(CFSetRef)insertions bell:(BOOL)bell {
  if(bell && bellSound){AudioServicesPlaySystemSound(bellSoundID);}
  UITableView* tableView=(UITableView*)self.view;
  [UIView setAnimationsEnabled:NO];
  if(changes){
    [tableView beginUpdates];
    unsigned int i;
    for (i=0;i<3;i++){
      CFSetRef iset=(i==0)?changes:(i==1)?deletions:insertions;
      CFIndex count=CFSetGetCount(iset),j;
      id* items=malloc(count*sizeof(id));
      CFSetGetValues(iset,(const void**)items);
      for (j=0;j<count;j++){
        items[j]=[NSIndexPath indexPathForRow:(NSUInteger)items[j] inSection:0];
      }
      NSArray* ipaths=[NSArray arrayWithObjects:items count:count];
      free(items);
      switch(i){
        case 0:[tableView reloadRowsAtIndexPaths:ipaths
         withRowAnimation:UITableViewRowAnimationNone];break;
        case 1:[tableView deleteRowsAtIndexPaths:ipaths
         withRowAnimation:UITableViewRowAnimationNone];break;
        case 2:[tableView insertRowsAtIndexPaths:ipaths
         withRowAnimation:UITableViewRowAnimationNone];break;
      }
    }
    [tableView endUpdates];
  }
  else {
    [tableView reloadSections:screenSection
     withRowAnimation:UITableViewRowAnimationNone];
  }
  [UIView setAnimationsEnabled:YES];
  [tableView scrollToRowAtIndexPath:
   [NSIndexPath indexPathForRow:terminal.numberOfLines-1 inSection:0]
   atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}
-(void)dealloc {
  CFRelease(colorBag);
  CFRelease(colorSpace);
  CFRelease(nullColor);
  CFRelease(ctFont);
  CFRelease(ctFontBold);
  CFRelease(ctFontItalic);
  CFRelease(ctFontBoldItalic);
  CFRelease(ctUnderlineStyleSingle);
  CFRelease(ctUnderlineStyleDouble);
  if(bellSound){AudioServicesDisposeSystemSoundID(bellSoundID);}
  [repeatTimer release];
  [screenSection release];
  [allTerminals release];
  [super dealloc];
}
@end

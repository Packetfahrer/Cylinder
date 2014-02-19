/*
Copyright (C) 2014 Reed Weichler

This file is part of Cylinder.

Cylinder is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Cylinder is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Cylinder.  If not, see <http://www.gnu.org/licenses/>.
*/

#import <substrate.h>
#import <UIKit/UIKit.h>
#import "luashit.h"
#import "macros.h"
#import "UIView+Cylinder.h"

static Class SBIconListView;
static IMP original_SB_scrollViewWillBeginDragging;
static IMP original_SB_scrollViewDidScroll;
static IMP original_SB_scrollViewDidEndDecelerating;
static IMP original_SB_wallpaperRelativeBounds;
static IMP original_SB_showIconImages;
static IMP original_SB_layerClass;

static BOOL _enabled;

static u_int32_t _rand;
static int _page = -100;

void reset_everything(UIView *view)
{
    view.layer.transform = CATransform3DIdentity;
    view.alpha = 1;
    for(UIView *v in view.subviews)
    {
        v.layer.transform = CATransform3DIdentity;
        v.alpha = 1;
    }
}

void genscrol(UIScrollView *scrollView, int i, UIView *view)
{
    CGSize size = scrollView.frame.size;
    float offset = scrollView.contentOffset.x;

    int page = (int)(offset/size.width);
    if(page != _page)
    {
        _rand = arc4random();
        _page = page;
    }

    if(IOS_VERSION < 7) i++; //on iOS 6-, the spotlight is a page to the left, so we gotta bump the pageno. up a notch
    offset -= i*size.width;

    _enabled = manipulate(view, offset, _rand);
}

void SB_scrollViewDidEndDecelerating(id self, SEL _cmd, UIScrollView 
*scrollView)
{
    original_SB_scrollViewDidEndDecelerating(self, _cmd, scrollView);
    for(UIView *view in scrollView.subviews)
        reset_everything(view);
}

void SB_scrollViewWillBeginDragging(id self, SEL _cmd, UIScrollView *scrollView)
{
    original_SB_scrollViewWillBeginDragging(self, _cmd, scrollView);
    [scrollView.superview sendSubviewToBack:scrollView];
}

static int biggestTo = 0;
void SB_showIconImages(UIView *self, SEL _cmd, int from, int to, int total, BOOL jittering)
{
    if(to > biggestTo) biggestTo = to;
    if(self.isOnScreen)
    {
        from = 0;
        to = biggestTo;
        total = biggestTo + 1;
    }
    original_SB_showIconImages(self, _cmd, from, to, total, jittering);
}

void SB_scrollViewDidScroll(id self, SEL _cmd, UIScrollView *scrollView)
{
    original_SB_scrollViewDidScroll(self, _cmd, scrollView);

    if(!_enabled) return;

    //NOTE: the code that follows is extremely bad and desparately needs improvement.

    float percent = scrollView.contentOffset.x/scrollView.frame.size.width;
    if(IOS_VERSION < 7) percent--;
    int start = -1;
    int count = 0;
    UIView *first = nil;
    UIView *last = nil;
    //only animate the pages that are visible
    for(int i = 0; i < scrollView.subviews.count; i++)
    {
        UIView *view = [scrollView.subviews objectAtIndex:i];
        if([view isKindOfClass:SBIconListView])
        {
            if(start == -1) start = i;
            view.isOnScreen = false;

            if(!first) first = view;
            last = view;
            count++;
        }
    }
    if(start != -1)
    {
        for(int i = 0; i < 2; i++)
        {
            int index = (int)(percent + i + start);
            if(index - start >= 0 && index < scrollView.subviews.count)
            {
                UIView *view = [scrollView.subviews objectAtIndex:index];
                view.isOnScreen = true;
                genscrol(scrollView, index - start, view);
            }
            //failed hotfix for mobius compatibility.
            /*
            if(i == 0 && percent + i < 0)
            {
                last.isOnScreen = true;
                genscrol(scrollView, -1, last);
            }
            else if(i == 1 && index - start == count)
            {
                first.isOnScreen = true;
                genscrol(scrollView, count, first);
            }
            */
        }
    }
}

//iOS 7 folder blur glitch hotfix for 3D effects.
typedef CGRect (*wprb_func)(id, SEL);
CGRect SB_wallpaperRelativeBounds(id self, SEL _cmd)
{
    wprb_func func = (wprb_func)(original_SB_wallpaperRelativeBounds);
    CGRect frame = func(self, _cmd);
    if(frame.origin.x < 0) frame.origin.x = 0;
    if(frame.origin.x > SCREEN_SIZE.width - frame.size.width) frame.origin.x = SCREEN_SIZE.width - frame.size.width;
    if(frame.origin.y > SCREEN_SIZE.height - frame.size.height) frame.origin.y = SCREEN_SIZE.height - frame.size.height;
    if(frame.origin.y < 0) frame.origin.y = 0;
    return frame;
}

//special thanks to @noahd for this fix: https://github.com/rweichler/cylinder/issues/17
Class SB_layerClass(id self, SEL _cmd)
{
    return [CATransformLayer class];
}

void load_that_shit()
{
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];

    if(settings && ![[settings valueForKey:PrefsEnabledKey] boolValue])
    {
        close_lua();
        _enabled = false;
    }
    else
    {
        BOOL random = [[settings valueForKey:PrefsRandomizedKey] boolValue];
        NSArray *effects = [settings valueForKey:PrefsEffectKey];
        if(![effects isKindOfClass:NSArray.class]) effects = nil; //this is for backwards compatibility
        _enabled = init_lua(effects, random);
    }
}

static inline void setSettingsNotification(CFNotificationCenterRef 
center, void *observer, CFStringRef name, const void *object, 
CFDictionaryRef userInfo)
{
    load_that_shit();
}

// The attribute forces this function to be called on load.
__attribute__((constructor))
static void initialize() {
    SBIconListView = NSClassFromString(@"SBIconListView"); //iOS 4+
    if(!SBIconListView) SBIconListView = NSClassFromString(@"SBIconList"); //iOS 3
    load_that_shit();

    //hook scroll                                   //iOS 6-              
//iOS 7
    Class cls = NSClassFromString(IOS_VERSION < 7 ? @"SBIconController" : @"SBFolderView");

    MSHookMessageEx(cls, @selector(scrollViewDidScroll:), (IMP)SB_scrollViewDidScroll, (IMP *)&original_SB_scrollViewDidScroll);
    MSHookMessageEx(cls, @selector(scrollViewDidEndDecelerating:), (IMP)SB_scrollViewDidEndDecelerating, (IMP *)&original_SB_scrollViewDidEndDecelerating);
    if(IOS_VERSION < 7)
        MSHookMessageEx(cls, @selector(scrollViewWillBeginDragging:), (IMP)SB_scrollViewWillBeginDragging, (IMP *)&original_SB_scrollViewWillBeginDragging);

    //iOS 7 bug hotfix
    cls = NSClassFromString(@"SBFolderIconBackgroundView");
    if(cls) MSHookMessageEx(cls, @selector(wallpaperRelativeBounds), (IMP)SB_wallpaperRelativeBounds, (IMP *)&original_SB_wallpaperRelativeBounds);

    //iOS 6- not-all-icons-showing hotfix
    if(SBIconListView) MSHookMessageEx(SBIconListView, @selector(showIconImagesFromColumn:toColumn:totalColumns:visibleIconsJitter:), (IMP)SB_showIconImages, (IMP *)&original_SB_showIconImages);

    //fix for https://github.com/rweichler/cylinder/issues/17
    if([SBIconListView respondsToSelector:@selector(layerClass)])
    {
        MSHookMessageEx(object_getClass(SBIconListView), @selector(layerClass), (IMP)SB_layerClass, (IMP *)&original_SB_layerClass);
    }
    else
    {
        const char *encoding = method_getTypeEncoding(class_getInstanceMethod(NSObject.class, @selector(class)));
        class_addMethod(object_getClass(SBIconListView), @selector(layerClass), (IMP)SB_layerClass, encoding);
    }

    //listen to notification center (for settings change)
    CFNotificationCenterRef r = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(r, NULL, &setSettingsNotification, (CFStringRef)kCylinderSettingsChanged, NULL, 0);
}

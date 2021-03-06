// Copyright (c) 2013 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#import "atom/browser/mac/atom_application_delegate.h"

#import "atom/browser/mac/atom_application.h"
#include "atom/browser/browser.h"
#include "atom/browser/mac/dict_util.h"
#include "base/allocator/allocator_shim.h"
#include "base/allocator/features.h"
#include "base/mac/mac_util.h"
#include "base/mac/scoped_objc_class_swizzler.h"
#include "base/strings/sys_string_conversions.h"
#include "base/values.h"

#if BUILDFLAG(USE_EXPERIMENTAL_ALLOCATOR_SHIM)
// On macOS 10.12, the IME system attempts to allocate a 2^64 size buffer,
// which would typically cause an OOM crash. To avoid this, the problematic
// method is swizzled out and the make-OOM-fatal bit is disabled for the
// duration of the original call. https://crbug.com/654695
static base::mac::ScopedObjCClassSwizzler* g_swizzle_imk_input_session;
@interface OOMDisabledIMKInputSession : NSObject
@end
@implementation OOMDisabledIMKInputSession
- (void)_coreAttributesFromRange:(NSRange)range
                 whichAttributes:(long long)attributes
               completionHandler:(void (^)(void))block {
  // The allocator flag is per-process, so other threads may temporarily
  // not have fatal OOM occur while this method executes, but it is better
  // than crashing when using IME.
  base::allocator::SetCallNewHandlerOnMallocFailure(false);
  g_swizzle_imk_input_session->GetOriginalImplementation()(self, _cmd, range,
                                                           attributes, block);
  base::allocator::SetCallNewHandlerOnMallocFailure(true);
}
@end
#endif  // BUILDFLAG(USE_EXPERIMENTAL_ALLOCATOR_SHIM)

@implementation AtomApplicationDelegate

- (void)setApplicationDockMenu:(atom::AtomMenuModel*)model {
  menu_controller_.reset([[AtomMenuController alloc] initWithModel:model
                                             useDefaultAccelerator:NO]);
}

- (void)applicationWillFinishLaunching:(NSNotification*)notify {
  // Don't add the "Enter Full Screen" menu item automatically.
  [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];

  atom::Browser::Get()->WillFinishLaunching();
}

- (void)applicationDidFinishLaunching:(NSNotification*)notify {
  NSUserNotification *user_notification = [notify userInfo][(id)@"NSApplicationLaunchUserNotificationKey"];

  if (user_notification.userInfo != nil) {
    std::unique_ptr<base::DictionaryValue> launch_info =
      atom::NSDictionaryToDictionaryValue(user_notification.userInfo);
    atom::Browser::Get()->DidFinishLaunching(*launch_info);
  } else {
    std::unique_ptr<base::DictionaryValue> empty_info(new base::DictionaryValue);
    atom::Browser::Get()->DidFinishLaunching(*empty_info);
  }

#if BUILDFLAG(USE_EXPERIMENTAL_ALLOCATOR_SHIM)
  // Disable fatal OOM to hack around an OS bug https://crbug.com/654695.
  if (base::mac::IsOS10_12()) {
    g_swizzle_imk_input_session = new base::mac::ScopedObjCClassSwizzler(
        NSClassFromString(@"IMKInputSession"),
        [OOMDisabledIMKInputSession class],
        @selector(_coreAttributesFromRange:whichAttributes:completionHandler:));
  }
#endif
}

- (NSMenu*)applicationDockMenu:(NSApplication*)sender {
  if (menu_controller_)
    return [menu_controller_ menu];
  else
    return nil;
}

- (BOOL)application:(NSApplication*)sender
           openFile:(NSString*)filename {
  std::string filename_str(base::SysNSStringToUTF8(filename));
  return atom::Browser::Get()->OpenFile(filename_str) ? YES : NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  atom::Browser* browser = atom::Browser::Get();
  if (browser->is_quiting()) {
    return NSTerminateNow;
  } else {
    // System started termination.
    atom::Browser::Get()->Quit();
    return NSTerminateCancel;
  }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication
                    hasVisibleWindows:(BOOL)flag {
  atom::Browser* browser = atom::Browser::Get();
  browser->Activate(static_cast<bool>(flag));
  return flag;
}

-  (BOOL)application:(NSApplication*)sender
continueUserActivity:(NSUserActivity*)userActivity
  restorationHandler:(void (^)(NSArray*restorableObjects))restorationHandler {
  std::string activity_type(base::SysNSStringToUTF8(userActivity.activityType));
  std::unique_ptr<base::DictionaryValue> user_info =
    atom::NSDictionaryToDictionaryValue(userActivity.userInfo);
  if (!user_info)
    return NO;

  atom::Browser* browser = atom::Browser::Get();
  return browser->ContinueUserActivity(activity_type, *user_info) ? YES : NO;
}

- (IBAction)newWindowForTab:(id)sender {
  atom::Browser::Get()->NewWindowForTab();
}

@end

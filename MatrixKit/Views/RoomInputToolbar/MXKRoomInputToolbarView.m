/*
 Copyright 2015 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKRoomInputToolbarView.h"

#import <MediaPlayer/MediaPlayer.h>
#import <MobileCoreServices/MobileCoreServices.h>

#import <Photos/Photos.h>
#import <AssetsLibrary/ALAsset.h>
#import <AssetsLibrary/ALAssetRepresentation.h>

#import "MXKImageView.h"

#import "MXKMediaManager.h"
#import "MXKTools.h"

#import "NSBundle+MatrixKit.h"
#import "NSData+MatrixKit.h"

#define MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE    1024
#define MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE   768
#define MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE    512

NSString *const kPasteboardItemPrefix = @"pasteboard-";

@interface MXKRoomInputToolbarView()
{
    /**
     Alert used to list options.
     */
    MXKAlert *optionsListView;
    
    /**
     Current media picker
     */
    UIImagePickerController *mediaPicker;
    
    /**
     Array of validation views (MXKImageView instances)
     */
    NSMutableArray *validationViews;
    
    /**
     Handle images attachment
     */
    MXKAlert *compressionPrompt;
    NSMutableArray *pendingImages;
}

@property (nonatomic) IBOutlet UIView *messageComposerContainer;

@end

@implementation MXKRoomInputToolbarView
@synthesize messageComposerContainer, inputAccessoryView;

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([MXKRoomInputToolbarView class])
                          bundle:[NSBundle bundleForClass:[MXKRoomInputToolbarView class]]];
}

+ (instancetype)roomInputToolbarView
{
    if ([[self class] nib])
    {
        return [[[self class] nib] instantiateWithOwner:nil options:nil].firstObject;
    }
    else
    {
        return [[self alloc] init];
    }
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    
    // Finalize setup
    [self setTranslatesAutoresizingMaskIntoConstraints: NO];
    
    // Reset default container background color
    messageComposerContainer.backgroundColor = [UIColor clearColor];
    
    // Set default toolbar background color
    self.backgroundColor = [UIColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1.0];
    
    // Disable send button
    self.rightInputToolbarButton.enabled = NO;
    
    // Localize string
    [_rightInputToolbarButton setTitle:[NSBundle mxk_localizedStringForKey:@"send"] forState:UIControlStateNormal];
    [_rightInputToolbarButton setTitle:[NSBundle mxk_localizedStringForKey:@"send"] forState:UIControlStateHighlighted];
    
    validationViews = [NSMutableArray array];
}

- (void)dealloc
{
    inputAccessoryView = nil;
    
    [self destroy];
}

- (IBAction)onTouchUpInside:(UIButton*)button
{
    if (button == self.leftInputToolbarButton)
    {
        if (optionsListView)
        {
            [optionsListView dismiss:NO];
            optionsListView = nil;
        }
        
        // Option button has been pressed
        // List available options
        __weak typeof(self) weakSelf = self;
        
        // Check whether media attachment is supported
        if ([self.delegate respondsToSelector:@selector(roomInputToolbarView:presentViewController:)])
        {
            optionsListView = [[MXKAlert alloc] initWithTitle:nil message:nil style:MXKAlertStyleActionSheet];
            
            [optionsListView addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"attach_media"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert)
            {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                strongSelf->optionsListView = nil;
                
                // Open media gallery
                strongSelf->mediaPicker = [[UIImagePickerController alloc] init];
                strongSelf->mediaPicker.delegate = strongSelf;
                strongSelf->mediaPicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                strongSelf->mediaPicker.allowsEditing = NO;
                strongSelf->mediaPicker.mediaTypes = [NSArray arrayWithObjects:(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie, nil];
                [strongSelf.delegate roomInputToolbarView:strongSelf presentViewController:strongSelf->mediaPicker];
            }];
            
            [optionsListView addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"capture_media"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert)
            {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                strongSelf->optionsListView = nil;
                
                // Open Camera
                strongSelf->mediaPicker = [[UIImagePickerController alloc] init];
                strongSelf->mediaPicker.delegate = strongSelf;
                strongSelf->mediaPicker.sourceType = UIImagePickerControllerSourceTypeCamera;
                strongSelf->mediaPicker.allowsEditing = NO;
                strongSelf->mediaPicker.mediaTypes = [NSArray arrayWithObjects:(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie, nil];
                [strongSelf.delegate roomInputToolbarView:strongSelf presentViewController:strongSelf->mediaPicker];
            }];
        }
        else
        {
            NSLog(@"[MXKRoomInputToolbarView] Attach media is not supported");
        }
        
        // Check whether user invitation is supported
        if ([self.delegate respondsToSelector:@selector(roomInputToolbarView:inviteMatrixUser:)])
        {
            if (!optionsListView)
            {
                optionsListView = [[MXKAlert alloc] initWithTitle:nil message:nil style:MXKAlertStyleActionSheet];
            }
            
            [optionsListView addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"invite_user"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert)
            {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                
                // Ask for userId to invite
                strongSelf->optionsListView = [[MXKAlert alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"user_id_title"] message:nil style:MXKAlertStyleAlert];
                strongSelf->optionsListView.cancelButtonIndex = [strongSelf->optionsListView addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert)
                {
                    __strong __typeof(weakSelf)strongSelf = weakSelf;
                    strongSelf->optionsListView = nil;
                }];
                
                [strongSelf->optionsListView addTextFieldWithConfigurationHandler:^(UITextField *textField)
                {
                    textField.secureTextEntry = NO;
                    textField.placeholder = [NSBundle mxk_localizedStringForKey:@"user_id_placeholder"];
                }];
                [strongSelf->optionsListView addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"invite"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert)
                {
                    UITextField *textField = [alert textFieldAtIndex:0];
                    NSString *userId = textField.text;
                    
                    __strong __typeof(weakSelf)strongSelf = weakSelf;
                    strongSelf->optionsListView = nil;
                    
                    if (userId.length)
                    {
                        [strongSelf.delegate roomInputToolbarView:strongSelf inviteMatrixUser:userId];
                    }
                }];
                
                [strongSelf.delegate roomInputToolbarView:strongSelf presentMXKAlert:strongSelf->optionsListView];
            }];
        }
        else
        {
            NSLog(@"[MXKRoomInputToolbarView] Invitation is not supported");
        }
        
        if (optionsListView)
        {
            optionsListView.cancelButtonIndex = [optionsListView addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert)
            {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                strongSelf->optionsListView = nil;
            }];
            
            optionsListView.sourceView = button;
            
            [self.delegate roomInputToolbarView:self presentMXKAlert:optionsListView];
        }
        else
        {
            NSLog(@"[MXKRoomInputToolbarView] No option is supported");
        }
    }
    else if (button == self.rightInputToolbarButton)
    {
        
        NSString *message = self.textMessage;
        
        // Reset message
        self.textMessage = nil;
        
        // Send button has been pressed
        if (message.length && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendTextMessage:)])
        {
            [self.delegate roomInputToolbarView:self sendTextMessage:message];
        }
    }
}

- (void)setPlaceholder:(NSString *)inPlaceholder
{
    _placeholder = inPlaceholder;
}

- (void)dismissKeyboard
{
    
}

- (void)dismissCompressionPrompt
{
    if (compressionPrompt)
    {
        [compressionPrompt dismiss:NO];
        compressionPrompt = nil;
    }
    
    if (pendingImages.count)
    {
        UIImage *firstImage = pendingImages.firstObject;
        [pendingImages removeObjectAtIndex:0];
        [self sendImage:firstImage withCompressionMode:MXKRoomInputToolbarCompressionModePrompt];
    }
}

- (void)destroy
{
    [self dismissValidationViews];
    validationViews = nil;
    
    if (optionsListView)
    {
        [optionsListView dismiss:NO];
        optionsListView = nil;
    }
    
    [self dismissMediaPicker];
    
    self.delegate = nil;
    
    pendingImages = nil;
    [self dismissCompressionPrompt];
}

#pragma mark - Attachment handling

- (void)sendSelectedImage:(UIImage*)selectedImage withCompressionMode:(MXKRoomInputToolbarCompressionMode)compressionMode andLocalURL:(NSURL*)imageURL
{
    // Retrieve image mimetype if the image is saved in photos library
    NSString *mimetype = nil;
    if (imageURL)
    {
        CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[imageURL.path pathExtension] , NULL);
        mimetype = (__bridge_transfer NSString *) UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType);
        CFRelease(uti);
    }
    else
    {
        // Save the image in user's photos library
        [MXKMediaManager saveImageToPhotosLibrary:selectedImage success:nil failure:nil];
    }
    
    // Send data without compression if the image type is not jpeg
    if (mimetype && [mimetype isEqualToString:@"image/jpeg"] == NO && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendImage:withMimeType:)])
    {
        // Check whether the url references the image in the AssetsLibrary framework
        if ([imageURL.scheme isEqualToString:@"assets-library"])
        {
            // Retrieve the local full-sized image URL
            // Use the Photos framework on iOS 8 and later (use AssetsLibrary framework on iOS < 8).
            Class PHAsset_class = NSClassFromString(@"PHAsset");
            if (PHAsset_class)
            {
                PHFetchResult *result = [PHAsset fetchAssetsWithALAssetURLs:@[imageURL] options:nil];
                if (result.count)
                {
                    PHAsset *asset = result[0];
                    PHContentEditingInputRequestOptions *option = [[PHContentEditingInputRequestOptions alloc] init];
                    [asset requestContentEditingInputWithOptions:option completionHandler:^(PHContentEditingInput *contentEditingInput, NSDictionary *info) {
                        
                        [self.delegate roomInputToolbarView:self sendImage:contentEditingInput.fullSizeImageURL withMimeType:mimetype];
                        
                    }];
                }
                else
                {
                    NSLog(@"[MXKRoomInputToolbarView] Attach image failed");
                }
            }
            else
            {
                ALAssetsLibrary *assetLibrary=[[ALAssetsLibrary alloc] init];
                [assetLibrary assetForURL:imageURL resultBlock:^(ALAsset *asset) {
                    
                    // asset may be nil if the image is not saved in photos library
                    if (asset)
                    {
                        ALAssetRepresentation* assetRepresentation = [asset defaultRepresentation];
                        [self.delegate roomInputToolbarView:self sendImage:assetRepresentation.url withMimeType:mimetype];
                    }
                    else
                    {
                        NSLog(@"[MXKRoomInputToolbarView] Attach image failed");
                    }
                    
                } failureBlock:^(NSError *err) {
                    
                    NSLog(@"[MXKRoomInputToolbarView] Attach image failed: %@", err);
                    
                }];
            }
        }
        else
        {
            // Consider the provided URL as the filesystem one
            [self.delegate roomInputToolbarView:self sendImage:imageURL withMimeType:mimetype];
        }
    }
    else
    {
        if ([self.delegate respondsToSelector:@selector(roomInputToolbarView:sendImage:)])
        {
            [self sendImage:selectedImage withCompressionMode:compressionMode];
        }
        else
        {
            NSLog(@"[MXKRoomInputToolbarView] Attach image is not supported");
        }
    }
}

- (void)sendImage:(UIImage*)image withCompressionMode:(MXKRoomInputToolbarCompressionMode)compressionMode
{
    if (optionsListView)
    {
        [optionsListView dismiss:NO];
        optionsListView = nil;
    }
    
    if (compressionPrompt && compressionMode == MXKRoomInputToolbarCompressionModePrompt)
    {
        // Delay the image sending
        if (!pendingImages)
        {
            pendingImages = [NSMutableArray arrayWithObject:image];
        }
        else
        {
            [pendingImages addObject:image];
        }
        return;
    }
    
    CGSize originalSize = image.size;
    NSLog(@"Selected image size : %f %f", originalSize.width, originalSize.height);
    
    CGSize smallSize;
    CGSize mediumSize;
    CGSize largeSize;
    
    long long smallFilesize  = 0;
    long long mediumFilesize = 0;
    long long largeFilesize  = 0;
    
    CGFloat actualLargeSize = MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE;
    
    // Compute the file size of the selected image
    NSData *selectedImageFileData = UIImageJPEGRepresentation(image, 0.9);
    long long originalFileSize = selectedImageFileData.length;
    NSLog(@"- image file size: %tu", originalFileSize);
    
    // Compute the file size for each compression level
    CGFloat maxSize = MAX(originalSize.width, originalSize.height);
    if (maxSize >= MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE)
    {
        smallSize = [MXKTools resizeImageSize:originalSize toFitInSize:CGSizeMake(MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE, MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE) canExpand:NO];
        
        smallFilesize = [MXKTools roundFileSize:(long long)(smallSize.width * smallSize.height * 0.20)];
        
        if (maxSize >= MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE)
        {
            mediumSize = [MXKTools resizeImageSize:originalSize toFitInSize:CGSizeMake(MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE, MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE) canExpand:NO];
            
            mediumFilesize = [MXKTools roundFileSize:(long long)(mediumSize.width * mediumSize.height * 0.20)];
            
            if (maxSize >= MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE)
            {
                // In case of panorama the large resolution (1024 x ...) is not relevant. We prefer consider the third of the panarama width.
                actualLargeSize = maxSize / 3;
                if (actualLargeSize < MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE)
                {
                    actualLargeSize = MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE;
                }
                else
                {
                    // Keep a multiple of predefined large size
                    actualLargeSize = floor(actualLargeSize / MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE) * MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE;
                }
                
                largeSize = [MXKTools resizeImageSize:originalSize toFitInSize:CGSizeMake(actualLargeSize, actualLargeSize) canExpand:NO];
                
                largeFilesize = [MXKTools roundFileSize:(long long)(largeSize.width * largeSize.height * 0.20)];
            }
            else
            {
                NSLog(@"- too small to fit in %d", MXKROOM_INPUT_TOOLBAR_VIEW_LARGE_IMAGE_SIZE);
            }
        }
        else
        {
            NSLog(@"- too small to fit in %d", MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE);
        }
    }
    else
    {
        NSLog(@"- too small to fit in %d", MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE);
    }
    
    // Apply the compression mode
    if (compressionMode == MXKRoomInputToolbarCompressionModePrompt && (smallFilesize || mediumFilesize || largeFilesize))
    {
        compressionPrompt = [[MXKAlert alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"attachment_size_prompt"] message:nil style:MXKAlertStyleActionSheet];
        __weak typeof(self) weakSelf = self;
        
        if (smallFilesize)
        {
            NSString *resolution = [NSString stringWithFormat:@"%@ (%d x %d)", [MXKTools fileSizeToString: (int)smallFilesize], (int)smallSize.width, (int)smallSize.height];
            NSString *title = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"attachment_small"], resolution];
            [compressionPrompt addActionWithTitle:title style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                
                // Send the small image
                UIImage *smallImage = [MXKTools resizeImage:image toFitInSize:CGSizeMake(MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE, MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE)];
                [strongSelf.delegate roomInputToolbarView:weakSelf sendImage:smallImage];
                
                [strongSelf dismissCompressionPrompt];
            }];
        }
        
        if (mediumFilesize)
        {
            NSString *resolution = [NSString stringWithFormat:@"%@ (%d x %d)", [MXKTools fileSizeToString: (int)mediumFilesize], (int)mediumSize.width, (int)mediumSize.height];
            NSString *title = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"attachment_medium"], resolution];
            [compressionPrompt addActionWithTitle:title style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                
                // Send the medium image
                UIImage *mediumImage = [MXKTools resizeImage:image toFitInSize:CGSizeMake(MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE, MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE)];
                [strongSelf.delegate roomInputToolbarView:weakSelf sendImage:mediumImage];
                
                [strongSelf dismissCompressionPrompt];
            }];
        }
        
        if (largeFilesize)
        {
            NSString *resolution = [NSString stringWithFormat:@"%@ (%d x %d)", [MXKTools fileSizeToString: (int)largeFilesize], (int)largeSize.width, (int)largeSize.height];
            NSString *title = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"attachment_large"], resolution];
            [compressionPrompt addActionWithTitle:title style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                
                // Send the large image
                UIImage *largeImage = [MXKTools resizeImage:image toFitInSize:CGSizeMake(actualLargeSize, actualLargeSize)];
                [strongSelf.delegate roomInputToolbarView:weakSelf sendImage:largeImage];
                
                [strongSelf dismissCompressionPrompt];
            }];
        }
        
        NSString *resolution = [NSString stringWithFormat:@"%@ (%d x %d)", [MXKTools fileSizeToString: (int)originalFileSize], (int)originalSize.width, (int)originalSize.height];
        NSString *title = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"attachment_original"], resolution];
        [compressionPrompt addActionWithTitle:title style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            
            // Send the original image
            [strongSelf.delegate roomInputToolbarView:weakSelf sendImage:image];
            
            [strongSelf dismissCompressionPrompt];
        }];
        
        compressionPrompt.cancelButtonIndex = [compressionPrompt addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            [strongSelf dismissCompressionPrompt];
        }];
        
        compressionPrompt.sourceView = self;
        
        [self.delegate roomInputToolbarView:self presentMXKAlert:compressionPrompt];
    }
    else
    {
        // By default the original image is sent
        UIImage *finalImage = image;
        
        switch (compressionMode)
        {
            case MXKRoomInputToolbarCompressionModePrompt:
                // Here the image size is too small to need compression - send the original image
                break;
                
            case MXKRoomInputToolbarCompressionModeSmall:
                if (smallFilesize)
                {
                    finalImage = [MXKTools resizeImage:image toFitInSize:CGSizeMake(MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE, MXKROOM_INPUT_TOOLBAR_VIEW_SMALL_IMAGE_SIZE)];
                }
                break;
                
            case MXKRoomInputToolbarCompressionModeMedium:
                if (mediumFilesize)
                {
                    finalImage = [MXKTools resizeImage:image toFitInSize:CGSizeMake(MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE, MXKROOM_INPUT_TOOLBAR_VIEW_MEDIUM_IMAGE_SIZE)];
                }
                break;
                
            case MXKRoomInputToolbarCompressionModeLarge:
                if (largeFilesize)
                {
                    finalImage = [MXKTools resizeImage:image toFitInSize:CGSizeMake(actualLargeSize, actualLargeSize)];
                }
                break;
                
            default:
                // no compression, send original
                break;
        }
        
        // Send the image
        [self.delegate roomInputToolbarView:self sendImage:finalImage];
    }
}

- (void)sendSelectedVideo:(NSURL*)selectedVideo isCameraRecording:(BOOL)isCameraRecording
{
    if (isCameraRecording)
    {
        [MXKMediaManager saveMediaToPhotosLibrary:selectedVideo isImage:NO success:nil failure:nil];
    }
    
    if ([self.delegate respondsToSelector:@selector(roomInputToolbarView:sendVideo:withThumbnail:)])
    {
        // Retrieve the video frame at 1 sec to define the video thumbnail
        AVURLAsset *urlAsset = [[AVURLAsset alloc] initWithURL:selectedVideo options:nil];
        AVAssetImageGenerator *assetImageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:urlAsset];
        assetImageGenerator.appliesPreferredTrackTransform = YES;
        CMTime time = CMTimeMake(1, 1);
        CGImageRef imageRef = [assetImageGenerator copyCGImageAtTime:time actualTime:NULL error:nil];
        
        // Finalize video attachment
        UIImage* videoThumbnail = [[UIImage alloc] initWithCGImage:imageRef];
        CFRelease(imageRef);
        
        [self.delegate roomInputToolbarView:self sendVideo:selectedVideo withThumbnail:videoThumbnail];
    }
    else
    {
        NSLog(@"[RoomInputToolbarView] Attach video is not supported");
    }
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    [self dismissMediaPicker];
    
    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:(NSString *)kUTTypeImage])
    {
        UIImage *selectedImage = [info objectForKey:UIImagePickerControllerOriginalImage];
        if (selectedImage)
        {
            // Media picker does not offer a preview
            // so add a preview to let the user validates his selection
            if (picker.sourceType == UIImagePickerControllerSourceTypePhotoLibrary)
            {
                __weak typeof(self) weakSelf = self;
                
                MXKImageView *imageValidationView = [[MXKImageView alloc] initWithFrame:CGRectZero];
                imageValidationView.stretchable = YES;
                
                // the user validates the image
                [imageValidationView setRightButtonTitle:[NSBundle mxk_localizedStringForKey:@"ok"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                 {
                     __strong __typeof(weakSelf)strongSelf = weakSelf;
                     
                     // Dismiss the image view
                     [strongSelf dismissValidationViews];
                     
                     // attach the selected image
                     [strongSelf sendSelectedImage:selectedImage withCompressionMode:MXKRoomInputToolbarCompressionModePrompt andLocalURL:[info objectForKey:UIImagePickerControllerReferenceURL]];
                 }];
                
                // the user wants to use an other image
                [imageValidationView setLeftButtonTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                 {
                     __strong __typeof(weakSelf)strongSelf = weakSelf;
                     
                     // dismiss the image view
                     [strongSelf dismissValidationViews];
                     
                     // Open again media gallery
                     strongSelf->mediaPicker = [[UIImagePickerController alloc] init];
                     strongSelf->mediaPicker.delegate = strongSelf;
                     strongSelf->mediaPicker.sourceType = picker.sourceType;
                     strongSelf->mediaPicker.allowsEditing = NO;
                     strongSelf->mediaPicker.mediaTypes = picker.mediaTypes;
                     [strongSelf.delegate roomInputToolbarView:strongSelf presentViewController:strongSelf->mediaPicker];
                 }];
                
                imageValidationView.image = selectedImage;
                
                [validationViews addObject:imageValidationView];
                [imageValidationView showFullScreen];
            }
            else
            {
                // Save the original image in user's photos library and suggest compression before sending image
                [self sendSelectedImage:selectedImage withCompressionMode:MXKRoomInputToolbarCompressionModePrompt andLocalURL:nil];
            }
        }
    }
    else if ([mediaType isEqualToString:(NSString *)kUTTypeMovie])
    {
        NSURL* selectedVideo = [info objectForKey:UIImagePickerControllerMediaURL];
        
        [self sendSelectedVideo:selectedVideo isCameraRecording:(picker.sourceType != UIImagePickerControllerSourceTypePhotoLibrary)];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self dismissMediaPicker];
}

- (void)dismissValidationViews
{
    for (MXKImageView *validationView in validationViews)
    {
        [validationView dismissSelection];
        [validationView removeFromSuperview];
    }
    
    [validationViews removeAllObjects];
}

- (void)dismissMediaPicker
{
    if (mediaPicker)
    {
        mediaPicker.delegate = nil;
        
        if ([self.delegate respondsToSelector:@selector(roomInputToolbarView:dismissViewControllerAnimated:completion:)])
        {
            [self.delegate roomInputToolbarView:self dismissViewControllerAnimated:NO completion:^{
                mediaPicker = nil;
            }];
        }
    }
}

#pragma mark - Clipboard - Handle image/data paste from general pasteboard

- (void)paste:(id)sender
{
    UIPasteboard *generalPasteboard = [UIPasteboard generalPasteboard];
    if (generalPasteboard.numberOfItems)
    {
        [self dismissValidationViews];
        [self dismissKeyboard];
        
        __weak typeof(self) weakSelf = self;
        
        for (NSDictionary* dict in generalPasteboard.items)
        {
            NSArray* allKeys = dict.allKeys;
            for (NSString* key in allKeys)
            {
                NSString* MIMEType = (__bridge_transfer NSString *) UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)key, kUTTagClassMIMEType);
                if ([MIMEType hasPrefix:@"image/"] && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendImage:)])
                {
                    UIImage *pasteboardImage = [dict objectForKey:key];
                    if (pasteboardImage)
                    {
                        MXKImageView *imageValidationView = [[MXKImageView alloc] initWithFrame:CGRectZero];
                        imageValidationView.stretchable = YES;
                        
                        // the user validates the image
                        [imageValidationView setRightButtonTitle:[NSBundle mxk_localizedStringForKey:@"ok"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                         {
                             __strong __typeof(weakSelf)strongSelf = weakSelf;
                             
                             // dismiss the image validation view
                             [imageView dismissSelection];
                             [imageView removeFromSuperview];
                             [validationViews removeObject:imageView];
                             
                             [strongSelf.delegate roomInputToolbarView:strongSelf sendImage:pasteboardImage];
                         }];
                        
                        // the user wants to use an other image
                        [imageValidationView setLeftButtonTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                         {
                             // dismiss the image validation view
                             [imageView dismissSelection];
                             [imageView removeFromSuperview];
                             [validationViews removeObject:imageView];
                             
                         }];
                        
                        imageValidationView.image = pasteboardImage;
                        
                        [validationViews addObject:imageValidationView];
                        [imageValidationView showFullScreen];
                    }
                    
                    break;
                }
                else if ([MIMEType hasPrefix:@"video/"] && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendVideo:withThumbnail:)])
                {
                    NSData *pasteboardVideoData = [dict objectForKey:key];
                    NSString *fakePasteboardURL = [NSString stringWithFormat:@"%@%@", kPasteboardItemPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
                    NSString *cacheFilePath = [MXKMediaManager cachePathForMediaWithURL:fakePasteboardURL andType:MIMEType inFolder:nil];
                    
                    if ([MXKMediaManager writeMediaData:pasteboardVideoData toFilePath:cacheFilePath])
                    {
                        NSURL *videoLocalURL = [NSURL fileURLWithPath:cacheFilePath isDirectory:NO];
                        
                        // Retrieve the video frame at 1 sec to define the video thumbnail
                        AVURLAsset *urlAsset = [[AVURLAsset alloc] initWithURL:videoLocalURL options:nil];
                        AVAssetImageGenerator *assetImageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:urlAsset];
                        assetImageGenerator.appliesPreferredTrackTransform = YES;
                        CMTime time = CMTimeMake(1, 1);
                        CGImageRef imageRef = [assetImageGenerator copyCGImageAtTime:time actualTime:NULL error:nil];
                        UIImage* videoThumbnail = [[UIImage alloc] initWithCGImage:imageRef];
                        CFRelease (imageRef);
                        
                        MXKImageView *videoValidationView = [[MXKImageView alloc] initWithFrame:CGRectZero];
                        videoValidationView.stretchable = YES;
                        
                        // the user validates the image
                        [videoValidationView setRightButtonTitle:[NSBundle mxk_localizedStringForKey:@"ok"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                         {
                             __strong __typeof(weakSelf)strongSelf = weakSelf;
                             
                             // dismiss the video validation view
                             [imageView dismissSelection];
                             [imageView removeFromSuperview];
                             [validationViews removeObject:imageView];
                             
                             [strongSelf.delegate roomInputToolbarView:strongSelf sendVideo:videoLocalURL withThumbnail:videoThumbnail];
                         }];
                        
                        // the user wants to use an other image
                        [videoValidationView setLeftButtonTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                         {
                             // dismiss the video validation view
                             [imageView dismissSelection];
                             [imageView removeFromSuperview];
                             [validationViews removeObject:imageView];
                             
                         }];
                        
                        videoValidationView.image = videoThumbnail;
                        
                        [validationViews addObject:videoValidationView];
                        [videoValidationView showFullScreen];
                        
                        // Add video icon
                        UIImageView *videoIconView = [[UIImageView alloc] initWithImage:[NSBundle mxk_imageFromMXKAssetsBundleWithName:@"icon_video"]];
                        videoIconView.center = videoValidationView.center;
                        videoIconView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
                        [videoValidationView addSubview:videoIconView];
                    }
                    break;
                }
                else if ([MIMEType hasPrefix:@"application/"] && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendFile:withMimeType:)])
                {
                    NSData *pasteboardDocumentData = [dict objectForKey:key];
                    NSString *fakePasteboardURL = [NSString stringWithFormat:@"%@%@", kPasteboardItemPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
                    NSString *cacheFilePath = [MXKMediaManager cachePathForMediaWithURL:fakePasteboardURL andType:MIMEType inFolder:nil];
                    
                    if ([MXKMediaManager writeMediaData:pasteboardDocumentData toFilePath:cacheFilePath])
                    {
                        NSURL *localURL = [NSURL fileURLWithPath:cacheFilePath isDirectory:NO];
                        
                        MXKImageView *docValidationView = [[MXKImageView alloc] initWithFrame:CGRectZero];
                        docValidationView.stretchable = YES;
                        
                        // the user validates the image
                        [docValidationView setRightButtonTitle:[NSBundle mxk_localizedStringForKey:@"ok"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                         {
                             __strong __typeof(weakSelf)strongSelf = weakSelf;
                             
                             // dismiss the video validation view
                             [imageView dismissSelection];
                             [imageView removeFromSuperview];
                             [validationViews removeObject:imageView];
                             
                             [strongSelf.delegate roomInputToolbarView:strongSelf sendFile:localURL withMimeType:MIMEType];
                         }];
                        
                        // the user wants to use an other image
                        [docValidationView setLeftButtonTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] handler:^(MXKImageView* imageView, NSString* buttonTitle)
                         {
                             // dismiss the video validation view
                             [imageView dismissSelection];
                             [imageView removeFromSuperview];
                             [validationViews removeObject:imageView];
                             
                         }];
                        
                        docValidationView.image = nil;
                        
                        [validationViews addObject:docValidationView];
                        [docValidationView showFullScreen];
                        
                        // Create a fake name based on fileData to keep the same name for the same file.
                        NSString *dataHash = [pasteboardDocumentData MD5];
                        if (dataHash.length > 7)
                        {
                            // Crop
                            dataHash = [dataHash substringToIndex:7];
                        }
                        NSString *extension = [MXKTools fileExtensionFromContentType:MIMEType];
                        NSString *filename = [NSString stringWithFormat:@"file_%@%@", dataHash, extension];
                        
                        // Display this file name
                        UITextView *fileNameTextView = [[UITextView alloc] initWithFrame:CGRectZero];
                        fileNameTextView.text = filename;
                        fileNameTextView.font = [UIFont systemFontOfSize:17];
                        [fileNameTextView sizeToFit];
                        fileNameTextView.center = docValidationView.center;
                        fileNameTextView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
                        
                        docValidationView.backgroundColor = [UIColor whiteColor];
                        [docValidationView addSubview:fileNameTextView];
                    }
                    break;
                }
            }
        }
    }
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
    if (action == @selector(paste:))
    {
        // Check whether some data listed in general pasteboard can be paste
        UIPasteboard *generalPasteboard = [UIPasteboard generalPasteboard];
        if (generalPasteboard.numberOfItems)
        {
            for (NSDictionary* dict in generalPasteboard.items)
            {
                NSArray* allKeys = dict.allKeys;
                for (NSString* key in allKeys)
                {
                    NSString* MIMEType = (__bridge_transfer NSString *) UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)key, kUTTagClassMIMEType);
                    
                    if ([MIMEType hasPrefix:@"image/"] && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendImage:)])
                    {
                        return YES;
                    }
                    
                    if ([MIMEType hasPrefix:@"video/"] && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendVideo:withThumbnail:)])
                    {
                        return YES;
                    }
                    
                    if ([MIMEType hasPrefix:@"application/"] && [self.delegate respondsToSelector:@selector(roomInputToolbarView:sendFile:withMimeType:)])
                    {
                        return YES;
                    }
                }
            }
        }
    }
    return NO;
}

@end
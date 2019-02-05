//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "ThreadUtil.h"
#import "OWSContactOffersInteraction.h"
#import "OWSContactsManager.h"
#import "OWSQuotedReplyModel.h"
#import "OWSUnreadIndicator.h"
#import "TSUnreadIndicatorInteraction.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalMessaging/OWSProfileManager.h>
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalServiceKit/OWSAddToContactsOfferMessage.h>
#import <SignalServiceKit/OWSAddToProfileWhitelistOfferMessage.h>
#import <SignalServiceKit/OWSBlockingManager.h>
#import <SignalServiceKit/OWSDisappearingMessagesConfiguration.h>
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/OWSUnknownContactBlockOfferMessage.h>
#import <SignalServiceKit/TSAccountManager.h>
#import <SignalServiceKit/TSCall.h>
#import <SignalServiceKit/TSContactThread.h>
#import <SignalServiceKit/TSDatabaseView.h>
#import <SignalServiceKit/TSIncomingMessage.h>
#import <SignalServiceKit/TSInvalidIdentityKeyErrorMessage.h>
#import <SignalServiceKit/TSOutgoingMessage.h>
#import <SignalServiceKit/TSThread.h>

NS_ASSUME_NONNULL_BEGIN

@interface ThreadDynamicInteractions ()

@property (nonatomic, nullable) NSNumber *focusMessagePosition;

@property (nonatomic, nullable) OWSUnreadIndicator *unreadIndicator;

@end

#pragma mark -

@implementation ThreadDynamicInteractions

- (void)clearUnreadIndicatorState
{
    self.unreadIndicator = nil;
}

@end

#pragma mark -

@implementation ThreadUtil

#pragma mark - Dependencies

+ (SSKMessageSenderJobQueue *)messageSenderJobQueue
{
    return SSKEnvironment.shared.messageSenderJobQueue;
}

+ (YapDatabaseConnection *)dbConnection
{
    return SSKEnvironment.shared.primaryStorage.dbReadWriteConnection;
}

#pragma mark - Durable Message Enqueue

+ (TSOutgoingMessage *)enqueueMessageWithText:(NSString *)text
                                     inThread:(TSThread *)thread
                             quotedReplyModel:(nullable OWSQuotedReplyModel *)quotedReplyModel
                             linkPreviewDraft:(nullable nullable OWSLinkPreviewDraft *)linkPreviewDraft
                                  transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSDisappearingMessagesConfiguration *configuration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:thread.uniqueId transaction:transaction];

    uint32_t expiresInSeconds = (configuration.isEnabled ? configuration.durationSeconds : 0);

    TSOutgoingMessage *message =
        [TSOutgoingMessage outgoingMessageInThread:thread
                                       messageBody:text
                                      attachmentId:nil
                                  expiresInSeconds:expiresInSeconds
                                     quotedMessage:[quotedReplyModel buildQuotedMessageForSending]
                                       linkPreview:nil];

    [BenchManager benchAsyncWithTitle:@"Saving outgoing message" block:^(void (^benchmarkCompletion)(void)) {
        // To avoid blocking the send flow, we dispatch an async write from within this read transaction
        [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull writeTransaction) {
            [message saveWithTransaction:writeTransaction];

            OWSLinkPreview *_Nullable linkPreview =
                [self linkPreviewForLinkPreviewDraft:linkPreviewDraft transaction:writeTransaction];
            if (linkPreview) {
                [message updateWithLinkPreview:linkPreview transaction:writeTransaction];
            }

            [self.messageSenderJobQueue addMessage:message transaction:writeTransaction];
        }
                                   completionBlock:benchmarkCompletion];
    }];

    return message;
}

+ (nullable OWSLinkPreview *)linkPreviewForLinkPreviewDraft:(nullable OWSLinkPreviewDraft *)linkPreviewDraft
                                                transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    if (!linkPreviewDraft) {
        return nil;
    }
    NSError *linkPreviewError;
    OWSLinkPreview *_Nullable linkPreview = [OWSLinkPreview buildValidatedLinkPreviewFromInfo:linkPreviewDraft
                                                                                  transaction:transaction
                                                                                        error:&linkPreviewError];
    if (linkPreviewError && ![OWSLinkPreview isNoPreviewError:linkPreviewError]) {
        OWSLogError(@"linkPreviewError: %@", linkPreviewError);
    }
    return linkPreview;
}

+ (TSOutgoingMessage *)enqueueMessageWithAttachment:(SignalAttachment *)attachment
                                           inThread:(TSThread *)thread
                                   quotedReplyModel:(nullable OWSQuotedReplyModel *)quotedReplyModel
{
    return [self enqueueMessageWithAttachments:@[
        attachment,
    ]
                                   messageBody:attachment.captionText
                                      inThread:thread
                              quotedReplyModel:quotedReplyModel];
}

+ (TSOutgoingMessage *)enqueueMessageWithAttachments:(NSArray<SignalAttachment *> *)attachments
                                         messageBody:(nullable NSString *)messageBody
                                            inThread:(TSThread *)thread
                                    quotedReplyModel:(nullable OWSQuotedReplyModel *)quotedReplyModel
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(attachments.count > 0);
    OWSAssertDebug(thread);
    for (SignalAttachment *attachment in attachments) {
        OWSAssertDebug(!attachment.hasError);
        OWSAssertDebug(attachment.mimeType.length > 0);
    }

    OWSDisappearingMessagesConfiguration *configuration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:thread.uniqueId];

    uint32_t expiresInSeconds = (configuration.isEnabled ? configuration.durationSeconds : 0);
    BOOL isVoiceMessage = (attachments.count == 1 && attachments.lastObject.isVoiceMessage);
    TSOutgoingMessage *message =
        [[TSOutgoingMessage alloc] initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                           inThread:thread
                                                        messageBody:messageBody
                                                      attachmentIds:[NSMutableArray new]
                                                   expiresInSeconds:expiresInSeconds
                                                    expireStartedAt:0
                                                     isVoiceMessage:isVoiceMessage
                                                   groupMetaMessage:TSGroupMetaMessageUnspecified
                                                      quotedMessage:[quotedReplyModel buildQuotedMessageForSending]
                                                       contactShare:nil
                                                        linkPreview:nil];

    NSMutableArray<OWSOutgoingAttachmentInfo *> *attachmentInfos = [NSMutableArray new];
    for (SignalAttachment *attachment in attachments) {
        OWSOutgoingAttachmentInfo *attachmentInfo = [attachment buildOutgoingAttachmentInfoWithMessage:message];
        [attachmentInfos addObject:attachmentInfo];
    }
    [self.messageSenderJobQueue addMediaMessage:message attachmentInfos:attachmentInfos isTemporaryAttachment:NO];

    return message;
}

+ (TSOutgoingMessage *)enqueueMessageWithContactShare:(OWSContact *)contactShare inThread:(TSThread *)thread;
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(contactShare);
    OWSAssertDebug(contactShare.ows_isValid);
    OWSAssertDebug(thread);

    OWSDisappearingMessagesConfiguration *configuration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:thread.uniqueId];

    uint32_t expiresInSeconds = (configuration.isEnabled ? configuration.durationSeconds : 0);
    TSOutgoingMessage *message =
        [[TSOutgoingMessage alloc] initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                           inThread:thread
                                                        messageBody:nil
                                                      attachmentIds:[NSMutableArray new]
                                                   expiresInSeconds:expiresInSeconds
                                                    expireStartedAt:0
                                                     isVoiceMessage:NO
                                                   groupMetaMessage:TSGroupMetaMessageUnspecified
                                                      quotedMessage:nil
                                                       contactShare:contactShare
                                                        linkPreview:nil];

    [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
        [message saveWithTransaction:transaction];
        [self.messageSenderJobQueue addMessage:message transaction:transaction];
    }];

    return message;
}

+ (void)enqueueLeaveGroupMessageInThread:(TSGroupThread *)thread
{
    OWSAssertDebug([thread isKindOfClass:[TSGroupThread class]]);

    TSOutgoingMessage *message =
        [TSOutgoingMessage outgoingMessageInThread:thread groupMetaMessage:TSGroupMetaMessageQuit expiresInSeconds:0];

    [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
        [self.messageSenderJobQueue addMessage:message transaction:transaction];
    }];
}

// MARK: Non-Durable Sending

// We might want to generate a link preview here.
+ (TSOutgoingMessage *)sendMessageNonDurablyWithText:(NSString *)text
                                            inThread:(TSThread *)thread
                                    quotedReplyModel:(nullable OWSQuotedReplyModel *)quotedReplyModel
                                       messageSender:(OWSMessageSender *)messageSender
                                             success:(void (^)(void))successHandler
                                             failure:(void (^)(NSError *error))failureHandler
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(text.length > 0);
    OWSAssertDebug(thread);
    OWSAssertDebug(messageSender);

    OWSDisappearingMessagesConfiguration *configuration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:thread.uniqueId];
    uint32_t expiresInSeconds = (configuration.isEnabled ? configuration.durationSeconds : 0);
    TSOutgoingMessage *message =
        [TSOutgoingMessage outgoingMessageInThread:thread
                                       messageBody:text
                                      attachmentId:nil
                                  expiresInSeconds:expiresInSeconds
                                     quotedMessage:[quotedReplyModel buildQuotedMessageForSending]
                                       linkPreview:nil];

    [messageSender sendMessage:message success:successHandler failure:failureHandler];

    return message;
}

+ (TSOutgoingMessage *)sendMessageNonDurablyWithAttachments:(NSArray<SignalAttachment *> *)attachments
                                                   inThread:(TSThread *)thread
                                                messageBody:(nullable NSString *)messageBody
                                           quotedReplyModel:(nullable OWSQuotedReplyModel *)quotedReplyModel
                                              messageSender:(OWSMessageSender *)messageSender
                                                 completion:(void (^_Nullable)(NSError *_Nullable error))completion
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(attachments.count > 0);
    OWSAssertDebug(thread);
    OWSAssertDebug(messageSender);

    OWSDisappearingMessagesConfiguration *configuration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:thread.uniqueId];

    uint32_t expiresInSeconds = (configuration.isEnabled ? configuration.durationSeconds : 0);
    BOOL isVoiceMessage = (attachments.count == 1 && attachments.firstObject.isVoiceMessage);
    // MJK TODO - remove senderTimestamp
    TSOutgoingMessage *message =
        [[TSOutgoingMessage alloc] initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                           inThread:thread
                                                        messageBody:messageBody
                                                      attachmentIds:[NSMutableArray new]
                                                   expiresInSeconds:expiresInSeconds
                                                    expireStartedAt:0
                                                     isVoiceMessage:isVoiceMessage
                                                   groupMetaMessage:TSGroupMetaMessageUnspecified
                                                      quotedMessage:[quotedReplyModel buildQuotedMessageForSending]
                                                       contactShare:nil
                                                        linkPreview:nil];

    NSMutableArray<OWSOutgoingAttachmentInfo *> *attachmentInfos = [NSMutableArray new];
    for (SignalAttachment *attachment in attachments) {
        OWSAssertDebug([attachment mimeType].length > 0);

        [attachmentInfos addObject:[attachment buildOutgoingAttachmentInfoWithMessage:message]];
    }

    [messageSender sendAttachments:attachmentInfos
        inMessage:message
        success:^{
            OWSLogDebug(@"Successfully sent message attachment.");
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    completion(nil);
                });
            }
        }
        failure:^(NSError *error) {
            OWSLogError(@"Failed to send message attachment with error: %@", error);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    completion(error);
                });
            }
        }];

    return message;
}

+ (TSOutgoingMessage *)sendMessageNonDurablyWithContactShare:(OWSContact *)contactShare
                                                    inThread:(TSThread *)thread
                                               messageSender:(OWSMessageSender *)messageSender
                                                  completion:(void (^_Nullable)(NSError *_Nullable error))completion
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(contactShare);
    OWSAssertDebug(contactShare.ows_isValid);
    OWSAssertDebug(thread);
    OWSAssertDebug(messageSender);

    OWSDisappearingMessagesConfiguration *configuration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:thread.uniqueId];

    uint32_t expiresInSeconds = (configuration.isEnabled ? configuration.durationSeconds : 0);
    // MJK TODO - remove senderTimestamp
    TSOutgoingMessage *message =
        [[TSOutgoingMessage alloc] initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                           inThread:thread
                                                        messageBody:nil
                                                      attachmentIds:[NSMutableArray new]
                                                   expiresInSeconds:expiresInSeconds
                                                    expireStartedAt:0
                                                     isVoiceMessage:NO
                                                   groupMetaMessage:TSGroupMetaMessageUnspecified
                                                      quotedMessage:nil
                                                       contactShare:contactShare
                                                        linkPreview:nil];

    [messageSender sendMessage:message
        success:^{
            OWSLogDebug(@"Successfully sent contact share.");
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    completion(nil);
                });
            }
        }
        failure:^(NSError *error) {
            OWSLogError(@"Failed to send contact share with error: %@", error);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    completion(error);
                });
            }
        }];

    return message;
}

#pragma mark - Dynamic Interactions

+ (ThreadDynamicInteractions *)ensureDynamicInteractionsForThread:(TSThread *)thread
                                                  contactsManager:(OWSContactsManager *)contactsManager
                                                  blockingManager:(OWSBlockingManager *)blockingManager
                                                     dbConnection:(YapDatabaseConnection *)dbConnection
                                      hideUnreadMessagesIndicator:(BOOL)hideUnreadMessagesIndicator
                                              lastUnreadIndicator:(nullable OWSUnreadIndicator *)lastUnreadIndicator
                                                   focusMessageId:(nullable NSString *)focusMessageId
                                                     maxRangeSize:(int)maxRangeSize
{
    OWSAssertDebug(thread);
    OWSAssertDebug(dbConnection);
    OWSAssertDebug(contactsManager);
    OWSAssertDebug(blockingManager);
    OWSAssertDebug(maxRangeSize > 0);

    ThreadDynamicInteractions *result = [ThreadDynamicInteractions new];

    [dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        // Find any "dynamic" interactions and safety number changes.
        //
        // We use different views for performance reasons.
        NSMutableArray<TSInvalidIdentityKeyErrorMessage *> *blockingSafetyNumberChanges = [NSMutableArray new];
        NSMutableArray<TSInteraction *> *nonBlockingSafetyNumberChanges = [NSMutableArray new];
        [[TSDatabaseView threadSpecialMessagesDatabaseView:transaction]
            enumerateKeysAndObjectsInGroup:thread.uniqueId
                                usingBlock:^(
                                    NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop) {
                                    if ([object isKindOfClass:[TSInvalidIdentityKeyErrorMessage class]]) {
                                        [blockingSafetyNumberChanges addObject:object];
                                    } else if ([object isKindOfClass:[TSErrorMessage class]]) {
                                        TSErrorMessage *errorMessage = (TSErrorMessage *)object;
                                        OWSAssertDebug(
                                            errorMessage.errorType == TSErrorMessageNonBlockingIdentityChange);
                                        [nonBlockingSafetyNumberChanges addObject:errorMessage];
                                    } else {
                                        OWSFailDebug(@"Unexpected dynamic interaction type: %@", [object class]);
                                    }
                                }];

        // Determine if there are "unread" messages in this conversation.
        // If we've been passed a firstUnseenInteractionTimestampParameter,
        // just use that value in order to preserve continuity of the
        // unread messages indicator after all messages in the conversation
        // have been marked as read.
        //
        // IFF this variable is non-null, there are unseen messages in the thread.
        NSNumber *_Nullable firstUnseenSortId = nil;
        if (lastUnreadIndicator) {
            firstUnseenSortId = @(lastUnreadIndicator.firstUnseenSortId);
        } else {
            TSInteraction *_Nullable firstUnseenInteraction =
                [[TSDatabaseView unseenDatabaseViewExtension:transaction] firstObjectInGroup:thread.uniqueId];
            if (firstUnseenInteraction) {
                firstUnseenSortId = @(firstUnseenInteraction.sortId);
            }
        }

        [self ensureUnreadIndicator:result
                                    thread:thread
                               transaction:transaction
                              maxRangeSize:maxRangeSize
               blockingSafetyNumberChanges:blockingSafetyNumberChanges
            nonBlockingSafetyNumberChanges:nonBlockingSafetyNumberChanges
               hideUnreadMessagesIndicator:hideUnreadMessagesIndicator
                         firstUnseenSortId:firstUnseenSortId];

        // Determine the position of the focus message _after_ performing any mutations
        // around dynamic interactions.
        if (focusMessageId != nil) {
            result.focusMessagePosition =
                [self focusMessagePositionForThread:thread transaction:transaction focusMessageId:focusMessageId];
        }
    }];

    return result;
}

+ (void)ensureUnreadIndicator:(ThreadDynamicInteractions *)dynamicInteractions
                             thread:(TSThread *)thread
                        transaction:(YapDatabaseReadTransaction *)transaction
                       maxRangeSize:(int)maxRangeSize
        blockingSafetyNumberChanges:(NSArray<TSInvalidIdentityKeyErrorMessage *> *)blockingSafetyNumberChanges
     nonBlockingSafetyNumberChanges:(NSArray<TSInteraction *> *)nonBlockingSafetyNumberChanges
        hideUnreadMessagesIndicator:(BOOL)hideUnreadMessagesIndicator
    firstUnseenSortId:(nullable NSNumber *)firstUnseenSortId
{
    OWSAssertDebug(dynamicInteractions);
    OWSAssertDebug(thread);
    OWSAssertDebug(transaction);
    OWSAssertDebug(blockingSafetyNumberChanges);
    OWSAssertDebug(nonBlockingSafetyNumberChanges);

    if (hideUnreadMessagesIndicator) {
        return;
    }
    if (!firstUnseenSortId) {
        // If there are no unseen interactions, don't show an unread indicator.
        return;
    }

    YapDatabaseViewTransaction *threadMessagesTransaction = [transaction ext:TSMessageDatabaseViewExtensionName];
    OWSAssertDebug([threadMessagesTransaction isKindOfClass:[YapDatabaseViewTransaction class]]);

    // Determine unread indicator position, if necessary.
    //
    // Enumerate in reverse to count the number of messages
    // after the unseen messages indicator.  Not all of
    // them are unnecessarily unread, but we need to tell
    // the messages view the position of the unread indicator,
    // so that it can widen its "load window" to always show
    // the unread indicator.
    __block long visibleUnseenMessageCount = 0;
    __block TSInteraction *interactionAfterUnreadIndicator = nil;
    __block BOOL hasMoreUnseenMessages = NO;
    [threadMessagesTransaction
        enumerateKeysAndObjectsInGroup:thread.uniqueId
                           withOptions:NSEnumerationReverse
                            usingBlock:^(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop) {
                                if (![object isKindOfClass:[TSInteraction class]]) {
                                    OWSFailDebug(@"Expected a TSInteraction: %@", [object class]);
                                    return;
                                }

                                TSInteraction *interaction = (TSInteraction *)object;

                                if (interaction.isDynamicInteraction) {
                                    // Ignore dynamic interactions, if any.
                                    return;
                                }

                                if (interaction.sortId < firstUnseenSortId.unsignedLongLongValue) {
                                    // By default we want the unread indicator to appear just before
                                    // the first unread message.
                                    *stop = YES;
                                    return;
                                }

                                visibleUnseenMessageCount++;

                                interactionAfterUnreadIndicator = interaction;

                                if (visibleUnseenMessageCount + 1 >= maxRangeSize) {
                                    // If there are more unseen messages than can be displayed in the
                                    // messages view, show the unread indicator at the top of the
                                    // displayed messages.
                                    *stop = YES;
                                    hasMoreUnseenMessages = YES;
                                }
                            }];

    if (!interactionAfterUnreadIndicator) {
        // If we can't find an interaction after the unread indicator,
        // don't show it.  All unread messages may have been deleted or
        // expired.
        return;
    }
    OWSAssertDebug(visibleUnseenMessageCount > 0);

    NSUInteger missingUnseenSafetyNumberChangeCount = 0;
    if (hasMoreUnseenMessages) {
        NSMutableSet<NSData *> *missingUnseenSafetyNumberChanges = [NSMutableSet set];
        for (TSInvalidIdentityKeyErrorMessage *safetyNumberChange in blockingSafetyNumberChanges) {
            BOOL isUnseen = safetyNumberChange.sortId >= firstUnseenSortId.unsignedLongLongValue;
            if (!isUnseen) {
                continue;
            }

            BOOL isMissing = safetyNumberChange.sortId < interactionAfterUnreadIndicator.sortId;
            if (!isMissing) {
                continue;
            }

            @try {
                NSData *_Nullable newIdentityKey = [safetyNumberChange throws_newIdentityKey];
                if (newIdentityKey == nil) {
                    OWSFailDebug(@"Safety number change was missing it's new identity key.");
                    continue;
                }

                [missingUnseenSafetyNumberChanges addObject:newIdentityKey];
            } @catch (NSException *exception) {
                OWSFailDebug(@"exception: %@", exception);
            }
        }

        // Count the de-duplicated "blocking" safety number changes and all
        // of the "non-blocking" safety number changes.
        missingUnseenSafetyNumberChangeCount
            = (missingUnseenSafetyNumberChanges.count + nonBlockingSafetyNumberChanges.count);
    }

    NSInteger unreadIndicatorPosition = visibleUnseenMessageCount;

    dynamicInteractions.unreadIndicator =
        [[OWSUnreadIndicator alloc] initWithFirstUnseenSortId:firstUnseenSortId.unsignedLongLongValue
                                        hasMoreUnseenMessages:hasMoreUnseenMessages
                         missingUnseenSafetyNumberChangeCount:missingUnseenSafetyNumberChangeCount
                                      unreadIndicatorPosition:unreadIndicatorPosition];
    OWSLogInfo(@"Creating Unread Indicator: %llu", dynamicInteractions.unreadIndicator.firstUnseenSortId);
}

+ (nullable NSNumber *)focusMessagePositionForThread:(TSThread *)thread
                                         transaction:(YapDatabaseReadTransaction *)transaction
                                      focusMessageId:(NSString *)focusMessageId
{
    OWSAssertDebug(thread);
    OWSAssertDebug(transaction);
    OWSAssertDebug(focusMessageId);

    YapDatabaseViewTransaction *databaseView = [transaction ext:TSMessageDatabaseViewExtensionName];

    NSString *_Nullable group = nil;
    NSUInteger index;
    BOOL success =
        [databaseView getGroup:&group index:&index forKey:focusMessageId inCollection:TSInteraction.collection];
    if (!success) {
        // This might happen if the focus message has disappeared
        // before this view could appear.
        OWSFailDebug(@"failed to find focus message index.");
        return nil;
    }
    if (![group isEqualToString:thread.uniqueId]) {
        OWSFailDebug(@"focus message has invalid group.");
        return nil;
    }
    NSUInteger count = [databaseView numberOfItemsInGroup:thread.uniqueId];
    if (index >= count) {
        OWSFailDebug(@"focus message has invalid index.");
        return nil;
    }
    NSUInteger position = (count - index) - 1;
    return @(position);
}

+ (BOOL)shouldShowGroupProfileBannerInThread:(TSThread *)thread blockingManager:(OWSBlockingManager *)blockingManager
{
    OWSAssertDebug(thread);
    OWSAssertDebug(blockingManager);

    if (!thread.isGroupThread) {
        return NO;
    }
    if ([OWSProfileManager.sharedManager isThreadInProfileWhitelist:thread]) {
        return NO;
    }
    if (![OWSProfileManager.sharedManager hasLocalProfile]) {
        return NO;
    }
    if ([blockingManager isThreadBlocked:thread]) {
        return NO;
    }

    BOOL hasUnwhitelistedMember = NO;
    NSArray<NSString *> *blockedPhoneNumbers = [blockingManager blockedPhoneNumbers];
    for (NSString *recipientId in thread.recipientIdentifiers) {
        if (![blockedPhoneNumbers containsObject:recipientId]
            && ![OWSProfileManager.sharedManager isUserInProfileWhitelist:recipientId]) {
            hasUnwhitelistedMember = YES;
            break;
        }
    }
    if (!hasUnwhitelistedMember) {
        return NO;
    }
    return YES;
}

+ (BOOL)addThreadToProfileWhitelistIfEmptyContactThread:(TSThread *)thread
{
    OWSAssertDebug(thread);

    if (thread.isGroupThread) {
        return NO;
    }
    if ([OWSProfileManager.sharedManager isThreadInProfileWhitelist:thread]) {
        return NO;
    }
    if (!thread.shouldThreadBeVisible) {
        [OWSProfileManager.sharedManager addThreadToProfileWhitelist:thread];
        return YES;
    } else {
        return NO;
    }
}

#pragma mark - Delete Content

+ (void)deleteAllContent
{
    OWSLogInfo(@"");

    [OWSPrimaryStorage.sharedManager.newDatabaseConnection
        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            [self removeAllObjectsInCollection:[TSThread collection] class:[TSThread class] transaction:transaction];
            [self removeAllObjectsInCollection:[TSInteraction collection]
                                         class:[TSInteraction class]
                                   transaction:transaction];
            [self removeAllObjectsInCollection:[TSAttachment collection]
                                         class:[TSAttachment class]
                                   transaction:transaction];
            [self removeAllObjectsInCollection:[SignalRecipient collection]
                                         class:[SignalRecipient class]
                                   transaction:transaction];
        }];
    [TSAttachmentStream deleteAttachments];
}

+ (void)removeAllObjectsInCollection:(NSString *)collection
                               class:(Class) class
                         transaction:(YapDatabaseReadWriteTransaction *)transaction {
    OWSAssertDebug(collection.length > 0);
    OWSAssertDebug(class);
    OWSAssertDebug(transaction);

    NSArray<NSString *> *_Nullable uniqueIds = [transaction allKeysInCollection:collection];
    if (!uniqueIds) {
        OWSFailDebug(@"couldn't load uniqueIds for collection: %@.", collection);
        return;
    }
    OWSLogInfo(@"Deleting %lu objects from: %@", (unsigned long)uniqueIds.count, collection);
    NSUInteger count = 0;
    for (NSString *uniqueId in uniqueIds) {
        // We need to fetch each object, since [TSYapDatabaseObject removeWithTransaction:] sometimes does important
        // work.
        TSYapDatabaseObject *_Nullable object = [class fetchObjectWithUniqueID:uniqueId transaction:transaction];
        if (!object) {
            OWSFailDebug(@"couldn't load object for deletion: %@.", collection);
            continue;
        }
        [object removeWithTransaction:transaction];
        count++;
    };
    OWSLogInfo(@"Deleted %lu/%lu objects from: %@", (unsigned long)count, (unsigned long)uniqueIds.count, collection);
}

#pragma mark - Find Content

+ (nullable TSInteraction *)findInteractionInThreadByTimestamp:(uint64_t)timestamp
                                                      authorId:(NSString *)authorId
                                                threadUniqueId:(NSString *)threadUniqueId
                                                   transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(timestamp > 0);
    OWSAssertDebug(authorId.length > 0);

    NSString *localNumber = [TSAccountManager localNumber];
    if (localNumber.length < 1) {
        OWSFailDebug(@"missing long number.");
        return nil;
    }

    NSArray<TSInteraction *> *interactions =
        [TSInteraction interactionsWithTimestamp:timestamp
                                          filter:^(TSInteraction *interaction) {
                                              NSString *_Nullable messageAuthorId = nil;
                                              if ([interaction isKindOfClass:[TSIncomingMessage class]]) {
                                                  TSIncomingMessage *incomingMessage = (TSIncomingMessage *)interaction;
                                                  messageAuthorId = incomingMessage.authorId;
                                              } else if ([interaction isKindOfClass:[TSOutgoingMessage class]]) {
                                                  messageAuthorId = localNumber;
                                              }
                                              if (messageAuthorId.length < 1) {
                                                  return NO;
                                              }

                                              if (![authorId isEqualToString:messageAuthorId]) {
                                                  return NO;
                                              }
                                              if (![interaction.uniqueThreadId isEqualToString:threadUniqueId]) {
                                                  return NO;
                                              }
                                              return YES;
                                          }
                                 withTransaction:transaction];
    if (interactions.count < 1) {
        return nil;
    }
    if (interactions.count > 1) {
        // In case of collision, take the first.
        OWSLogError(@"more than one matching interaction in thread.");
    }
    return interactions.firstObject;
}

@end

NS_ASSUME_NONNULL_END

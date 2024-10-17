import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import ChatPresentationInterfaceState
import ChatControllerInteraction
import WebUI
import AttachmentUI
import AccountContext
import TelegramNotices
import PresentationDataUtils
import UndoUI
import UrlHandling
import TelegramPresentationData

func openWebAppImpl(context: AccountContext, parentController: ViewController, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?, peer: EnginePeer, threadId: Int64?, buttonText: String, url: String, simple: Bool, source: ChatOpenWebViewSource, skipTermsOfService: Bool, payload: String?) {
    let presentationData: PresentationData
    if let parentController = parentController as? ChatControllerImpl {
        presentationData = parentController.presentationData
    } else {
        presentationData = context.sharedContext.currentPresentationData.with({ $0 })
    }
    
    let botName: String
    let botAddress: String
    let botVerified: Bool
    if case let .inline(bot) = source {
        botName = bot.compactDisplayTitle
        botAddress = bot.addressName ?? ""
        botVerified = bot.isVerified
    } else {
        botName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        botAddress = peer.addressName ?? ""
        botVerified = peer.isVerified
    }
    
    if source == .generic {
        if let parentController = parentController as? ChatControllerImpl {
            parentController.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                return $0.updatedTitlePanelContext {
                    if !$0.contains(where: {
                        switch $0 {
                        case .requestInProgress:
                            return true
                        default:
                            return false
                        }
                    }) {
                        var updatedContexts = $0
                        updatedContexts.append(.requestInProgress)
                        return updatedContexts.sorted()
                    }
                    return $0
                }
            })
        }
    }
    
    let updateProgress = { [weak parentController] in
        Queue.mainQueue().async {
            if let parentController = parentController as? ChatControllerImpl {
                parentController.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedTitlePanelContext {
                        if let index = $0.firstIndex(where: {
                            switch $0 {
                                case .requestInProgress:
                                    return true
                                default:
                                    return false
                            }
                        }) {
                            var updatedContexts = $0
                            updatedContexts.remove(at: index)
                            return updatedContexts
                        }
                        return $0
                    }
                })
            }
        }
    }
            

    let openWebView = { [weak parentController] in
        guard let parentController else {
            return
        }
        if source == .menu {
            if let parentController = parentController as? ChatControllerImpl {
                parentController.updateChatPresentationInterfaceState(interactive: false) { state in
                    return state.updatedForceInputCommandsHidden(true)
                }
            }
            
            if let navigationController = parentController.navigationController as? NavigationController, let minimizedContainer = navigationController.minimizedContainer {
                for controller in minimizedContainer.controllers {
                    if let controller = controller as? AttachmentController, let mainController = controller.mainController as? WebAppController, mainController.botId == peer.id && mainController.source == .menu {
                        navigationController.maximizeViewController(controller, animated: true)
                        return
                    }
                }
            }
            
            var fullSize = false
            if isTelegramMeLink(url), let internalUrl = parseFullInternalUrl(sharedContext: context.sharedContext, url: url), case .peer(_, .appStart) = internalUrl {
                fullSize = !url.contains("?mode=compact")
            }

            var presentImpl: ((ViewController, Any?) -> Void)?
            let params = WebAppParameters(source: .menu, peerId: peer.id, botId: peer.id, botName: botName, botVerified: botVerified, url: url, queryId: nil, payload: nil, buttonText: buttonText, keepAliveSignal: nil, forceHasSettings: false, fullSize: fullSize)
            let controller = standaloneWebAppController(context: context, updatedPresentationData: updatedPresentationData, params: params, threadId: threadId, openUrl: { [weak parentController] url, concealed, commit in
                ChatControllerImpl.botOpenUrl(context: context, peerId: peer.id, controller: parentController as? ChatControllerImpl, url: url, concealed: concealed, present: { c, a in
                    presentImpl?(c, a)
                }, commit: commit)
            }, requestSwitchInline: { [weak parentController] query, chatTypes, completion in
                ChatControllerImpl.botRequestSwitchInline(context: context, controller: parentController as? ChatControllerImpl, peerId: peer.id, botAddress: botAddress, query: query, chatTypes: chatTypes, completion: completion)
            }, getInputContainerNode: { [weak parentController] in
                if let parentController = parentController as? ChatControllerImpl, let layout = parentController.validLayout, case .compact = layout.metrics.widthClass {
                    return (parentController.chatDisplayNode.getWindowInputAccessoryHeight(), parentController.chatDisplayNode.inputPanelContainerNode, {
                        return parentController.chatDisplayNode.textInputPanelNode?.makeAttachmentMenuTransition(accessoryPanelNode: nil)
                    })
                } else {
                    return nil
                }
            }, completion: { [weak parentController] in
                if let parentController = parentController as? ChatControllerImpl {
                    parentController.chatDisplayNode.historyNode.scrollToEndOfHistory()
                }
            }, willDismiss: { [weak parentController] in
                if let parentController = parentController as? ChatControllerImpl {
                    parentController.interfaceInteraction?.updateShowWebView { _ in
                        return false
                    }
                }
            }, didDismiss: { [weak parentController] in
                if let parentController = parentController as? ChatControllerImpl {
                    parentController.updateChatPresentationInterfaceState(interactive: false) { state in
                        return state.updatedForceInputCommandsHidden(false)
                    }
                }
            }, getNavigationController: { [weak parentController] in
                var navigationController: NavigationController?
                if let parentController = parentController as? ChatControllerImpl {
                    navigationController = parentController.effectiveNavigationController
                }
                return navigationController ?? (context.sharedContext.mainWindow?.viewController as? NavigationController)
            })
            controller.navigationPresentation = .flatModal
            parentController.push(controller)
            
            presentImpl = { [weak controller] c, a in
                controller?.present(c, in: .window(.root), with: a)
            }
        } else if simple {
            var isInline = false
            var botId = peer.id
            var botName = botName
            var botAddress = ""
            var botVerified = peer.isVerified
            if case let .inline(bot) = source {
                isInline = true
                botId = bot.id
                botName = bot.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                botAddress = bot.addressName ?? ""
                botVerified = bot.isVerified
            }
            
            let messageActionCallbackDisposable: MetaDisposable
            if let parentController = parentController as? ChatControllerImpl {
                messageActionCallbackDisposable = parentController.messageActionCallbackDisposable
            } else {
                messageActionCallbackDisposable = MetaDisposable()
            }
            
            let webViewSignal: Signal<RequestWebViewResult, RequestWebViewError>
            if url.isEmpty {
                webViewSignal = context.engine.messages.requestMainWebView(botId: botId, source: isInline ? .inline : .generic, themeParams: generateWebAppThemeParams(presentationData.theme))
            } else {
                webViewSignal = context.engine.messages.requestSimpleWebView(botId: botId, url: url, source: isInline ? .inline : .generic, themeParams: generateWebAppThemeParams(presentationData.theme))
            }
            
            messageActionCallbackDisposable.set(((webViewSignal
            |> afterDisposed {
                updateProgress()
            })
            |> deliverOnMainQueue).start(next: { [weak parentController] result in
                guard let parentController else {
                    return
                }
                var presentImpl: ((ViewController, Any?) -> Void)?
                let source: WebAppParameters.Source
                if isInline {
                    source = .inline
                } else {
                    source = url.isEmpty ? .generic : .simple
                }
                let params = WebAppParameters(source: source, peerId: peer.id, botId: botId, botName: botName, botVerified: botVerified, url: result.url, queryId: nil, payload: payload, buttonText: buttonText, keepAliveSignal: nil, forceHasSettings: false, fullSize: result.flags.contains(.fullSize))
                let controller = standaloneWebAppController(context: context, updatedPresentationData: updatedPresentationData, params: params, threadId: threadId, openUrl: { [weak parentController] url, concealed, commit in
                    ChatControllerImpl.botOpenUrl(context: context, peerId: peer.id, controller: parentController as? ChatControllerImpl, url: url, concealed: concealed, present: { c, a in
                        presentImpl?(c, a)
                    }, commit: commit)
                }, requestSwitchInline: { [weak parentController] query, chatTypes, completion in
                    ChatControllerImpl.botRequestSwitchInline(context: context, controller: parentController as? ChatControllerImpl, peerId: peer.id, botAddress: botAddress, query: query, chatTypes: chatTypes, completion: completion)
                }, getNavigationController: { [weak parentController] in
                    var navigationController: NavigationController?
                    if let parentController = parentController as? ChatControllerImpl {
                        navigationController = parentController.effectiveNavigationController
                    }
                    return navigationController ?? (context.sharedContext.mainWindow?.viewController as? NavigationController)
                })
                controller.navigationPresentation = .flatModal
                if let parentController = parentController as? ChatControllerImpl {
                    parentController.currentWebAppController = controller
                }
                parentController.push(controller)
                
                presentImpl = { [weak controller] c, a in
                    controller?.present(c, in: .window(.root), with: a)
                }
            }, error: { [weak parentController] error in
                if let parentController {
                    parentController.present(textAlertController(context: context, updatedPresentationData: updatedPresentationData, title: nil, text: presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {
                    })]), in: .window(.root))
                }
            }))
        } else {
            let messageActionCallbackDisposable: MetaDisposable
            if let parentController = parentController as? ChatControllerImpl {
                messageActionCallbackDisposable = parentController.messageActionCallbackDisposable
            } else {
                messageActionCallbackDisposable = MetaDisposable()
            }
            
            messageActionCallbackDisposable.set(((context.engine.messages.requestWebView(peerId: peer.id, botId: peer.id, url: !url.isEmpty ? url : nil, payload: nil, themeParams: generateWebAppThemeParams(presentationData.theme), fromMenu: false, replyToMessageId: nil, threadId: threadId)
            |> afterDisposed {
                updateProgress()
            })
            |> deliverOnMainQueue).startStandalone(next: { [weak parentController] result in
                guard let parentController else {
                    return
                }
                var presentImpl: ((ViewController, Any?) -> Void)?
                let params = WebAppParameters(source: .button, peerId: peer.id, botId: peer.id, botName: botName, botVerified: botVerified, url: result.url, queryId: result.queryId, payload: nil, buttonText: buttonText, keepAliveSignal: result.keepAliveSignal, forceHasSettings: false, fullSize: result.flags.contains(.fullSize))
                let controller = standaloneWebAppController(context: context, updatedPresentationData: updatedPresentationData, params: params, threadId: threadId, openUrl: { [weak parentController] url, concealed, commit in
                    ChatControllerImpl.botOpenUrl(context: context, peerId: peer.id, controller: parentController as? ChatControllerImpl, url: url, concealed: concealed, present: { c, a in
                        presentImpl?(c, a)
                    }, commit: commit)
                }, completion: { [weak parentController] in
                    if let parentController = parentController as? ChatControllerImpl {
                        parentController.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    }
                }, getNavigationController: { [weak parentController] in
                    var navigationController: NavigationController?
                    if let parentController = parentController as? ChatControllerImpl {
                        navigationController = parentController.effectiveNavigationController
                    }
                    return navigationController ?? (context.sharedContext.mainWindow?.viewController as? NavigationController)
                })
                controller.navigationPresentation = .flatModal
                if let parentController = parentController as? ChatControllerImpl {
                    parentController.currentWebAppController = controller
                }
                parentController.push(controller)
                
                presentImpl = { [weak controller] c, a in
                    controller?.present(c, in: .window(.root), with: a)
                }
            }, error: { [weak parentController] error in
                if let parentController {
                    parentController.present(textAlertController(context: context, updatedPresentationData: updatedPresentationData, title: nil, text: presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {
                    })]), in: .window(.root))
                }
            }))
        }
    }
    
    if skipTermsOfService {
        openWebView()
    } else {
        var botPeer = peer
        if case let .inline(bot) = source {
            botPeer = bot
        }
        let _ = (ApplicationSpecificNotice.getBotGameNotice(accountManager: context.sharedContext.accountManager, peerId: botPeer.id)
        |> deliverOnMainQueue).startStandalone(next: { [weak parentController] value in
            guard let parentController else {
                return
            }
            
            if value {
                openWebView()
            } else {
                let controller = webAppLaunchConfirmationController(context: context, updatedPresentationData: updatedPresentationData, peer: botPeer, completion: { _ in
                    let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                    openWebView()
                }, showMore: nil, openTerms: {
                    
                })
                parentController.present(controller, in: .window(.root))
            }
        })
    }
}

public extension ChatControllerImpl {
    func openWebApp(buttonText: String, url: String, simple: Bool, source: ChatOpenWebViewSource) {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return
        }
        self.chatDisplayNode.dismissInput()
        
        self.context.sharedContext.openWebApp(context: self.context, parentController: self, updatedPresentationData: self.updatedPresentationData, peer: EnginePeer(peer), threadId: self.chatLocation.threadId, buttonText: buttonText, url: url, simple: simple, source: source, skipTermsOfService: false, payload: nil)
    }
    
    static func botRequestSwitchInline(context: AccountContext, controller: ChatControllerImpl?, peerId: EnginePeer.Id, botAddress: String, query: String, chatTypes: [ReplyMarkupButtonRequestPeerType]?, completion:  @escaping () -> Void) -> Void {
        let activateSwitchInline: (EnginePeer?) -> Void = { selectedPeer in
            var chatController: ChatControllerImpl?
            if let current = controller {
                chatController = current
            } else if let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController {
                for controller in navigationController.viewControllers.reversed() {
                    if let controller = controller as? ChatControllerImpl {
                        chatController = controller
                        break
                    }
                }
            }
            if let chatController {
                chatController.controllerInteraction?.activateSwitchInline(selectedPeer?.id ?? peerId, "@\(botAddress) \(query)", nil)
            }
        }
    
        if let chatTypes {
            let peerController = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages], requestPeerType: chatTypes, hasContactSelector: false, hasCreation: false))
            peerController.peerSelected = { [weak peerController] peer, _ in
                completion()
                peerController?.dismiss()
                activateSwitchInline(peer)
            }
            if let controller {
                controller.push(peerController)
            } else {
                ((context.sharedContext.mainWindow?.viewController as? TelegramRootControllerInterface)?.viewControllers.last as? ViewController)?.push(peerController)
            }
        } else {
            activateSwitchInline(nil)
        }
    }
    
    private static func botOpenPeer(context: AccountContext, peerId: EnginePeer.Id, navigation: ChatControllerInteractionNavigateToPeer, navigationController: NavigationController) {
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).startStandalone(next: { peer in
            guard let peer else {
                return
            }
            switch navigation {
            case .default:
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), keepStack: .always))
            case let .chat(_, subject, peekData):
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), subject: subject, keepStack: .always, peekData: peekData))
            case .info:
                if peer.restrictionText(platform: "ios", contentSettings: context.currentContentSettings.with { $0 }) == nil {
                    if let infoController = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer._asPeer(), mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) {
                        navigationController.pushViewController(infoController)
                    }
                }
            case let .withBotStartPayload(startPayload):
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), botStart: startPayload))
            case let .withAttachBot(attachBotStart):
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), attachBotStart: attachBotStart))
            case let .withBotApp(botAppStart):
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), botAppStart: botAppStart, keepStack: .always))
            }
        })
    }
    
    static func botOpenUrl(context: AccountContext, peerId: EnginePeer.Id, controller: ChatControllerImpl?, url: String, concealed: Bool, present: @escaping (ViewController, Any?) -> Void, commit: @escaping () -> Void = {}) {
        if let controller {
            controller.openUrl(url, concealed: concealed, forceExternal: true, commit: commit)
        } else {
            let _ = openUserGeneratedUrl(context: context, peerId: peerId, url: url, concealed: concealed, present: { c in
                present(c, nil)
            }, openResolved: { result in
                var navigationController: NavigationController?
                if let current = controller?.navigationController as? NavigationController {
                    navigationController = current
                } else if let main = context.sharedContext.mainWindow?.viewController as? NavigationController {
                    navigationController = main
                }
                context.sharedContext.openResolvedUrl(result, context: context, urlContext: .generic, navigationController: navigationController, forceExternal: false, openPeer: { peer, navigation in
                    if let navigationController {
                        ChatControllerImpl.botOpenPeer(context: context, peerId: peer.id, navigation: navigation, navigationController: navigationController)
                    }
                    commit()
                }, sendFile: nil, sendSticker: nil, sendEmoji: nil, requestMessageActionUrlAuth: nil, joinVoiceChat: { peerId, invite, call in
                },
                present: { c, a in
                    present(c, a)
                }, dismissInput: {
                    context.sharedContext.mainWindow?.viewController?.view.endEditing(false)
                }, contentContext: nil, progress: nil, completion: nil)
            })
        }
    }
    
    func presentBotApp(botApp: BotApp?, botPeer: EnginePeer, payload: String?, compact: Bool, concealed: Bool = false, commit: @escaping () -> Void = {}) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        self.attachmentController?.dismiss(animated: true, completion: nil)
        
        if let botApp {
            let openBotApp: (Bool, Bool) -> Void = { [weak self] allowWrite, justInstalled in
                guard let strongSelf = self else {
                    return
                }
                commit()
                
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedTitlePanelContext {
                        if !$0.contains(where: {
                            switch $0 {
                            case .requestInProgress:
                                return true
                            default:
                                return false
                            }
                        }) {
                            var updatedContexts = $0
                            updatedContexts.append(.requestInProgress)
                            return updatedContexts.sorted()
                        }
                        return $0
                    }
                })
                
                let updateProgress = { [weak self] in
                    Queue.mainQueue().async {
                        if let strongSelf = self {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                return $0.updatedTitlePanelContext {
                                    if let index = $0.firstIndex(where: {
                                        switch $0 {
                                        case .requestInProgress:
                                            return true
                                        default:
                                            return false
                                        }
                                    }) {
                                        var updatedContexts = $0
                                        updatedContexts.remove(at: index)
                                        return updatedContexts
                                    }
                                    return $0
                                }
                            })
                        }
                    }
                }
                
                let botAddress = botPeer.addressName ?? ""
                strongSelf.messageActionCallbackDisposable.set(((strongSelf.context.engine.messages.requestAppWebView(peerId: peerId, appReference: .id(id: botApp.id, accessHash: botApp.accessHash), payload: payload, themeParams: generateWebAppThemeParams(strongSelf.presentationData.theme), compact: compact, allowWrite: allowWrite)
                |> afterDisposed {
                    updateProgress()
                })
                |> deliverOnMainQueue).startStrict(next: { [weak self] result in
                    guard let strongSelf = self else {
                        return
                    }
                    let context = strongSelf.context
                    let params = WebAppParameters(source: .generic, peerId: peerId, botId: botPeer.id, botName: botApp.title, botVerified: botPeer.isVerified, url: result.url, queryId: 0, payload: payload, buttonText: "", keepAliveSignal: nil, forceHasSettings: botApp.flags.contains(.hasSettings), fullSize: result.flags.contains(.fullSize))
                    var presentImpl: ((ViewController, Any?) -> Void)?
                    let controller = standaloneWebAppController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, params: params, threadId: strongSelf.chatLocation.threadId, openUrl: { [weak self] url, concealed, commit in
                        ChatControllerImpl.botOpenUrl(context: context, peerId: peerId, controller: self, url: url, concealed: concealed, present: { c, a in
                            presentImpl?(c, a)
                        }, commit: commit)
                    }, requestSwitchInline: { [weak self] query, chatTypes, completion in
                        ChatControllerImpl.botRequestSwitchInline(context: context, controller: self, peerId: peerId, botAddress: botAddress, query: query, chatTypes: chatTypes, completion: completion)
                    }, completion: { [weak self] in
                        self?.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    }, getNavigationController: { [weak self] in
                        return self?.effectiveNavigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController
                    })
                    controller.navigationPresentation = .flatModal
                    strongSelf.currentWebAppController = controller
                    strongSelf.push(controller)
                    
                    presentImpl = { [weak controller] c, a in
                        controller?.present(c, in: .window(.root), with: a)
                    }
                    
                    if justInstalled {
                        let content: UndoOverlayContent = .succeed(text: strongSelf.presentationData.strings.WebApp_ShortcutsSettingsAdded(botPeer.compactDisplayTitle).string, timeout: 5.0, customUndoText: nil)
                        controller.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: content, elevatedLayout: false, position: .top, action: { _ in return false }), in: .current)
                    }
                }, error: { [weak self] error in
                    if let strongSelf = self {
                        strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                        })]), in: .window(.root))
                    }
                }))
            }
            
            let _ = combineLatest(
                queue: Queue.mainQueue(),
                ApplicationSpecificNotice.getBotGameNotice(accountManager: self.context.sharedContext.accountManager, peerId: botPeer.id),
                self.context.engine.messages.attachMenuBots(),
                self.context.engine.messages.getAttachMenuBot(botId: botPeer.id, cached: true)
                |> map(Optional.init)
                |> `catch` { _ -> Signal<AttachMenuBot?, NoError> in
                    return .single(nil)
                }
            ).startStandalone(next: { [weak self] noticed, attachMenuBots, attachMenuBot in
                guard let self else {
                    return
                }
                
                var isAttachMenuBotInstalled: Bool?
                if let _ = attachMenuBot {
                    if let _ = attachMenuBots.first(where: { $0.peer.id == botPeer.id && !$0.flags.contains(.notActivated) }) {
                        isAttachMenuBotInstalled = true
                    } else {
                        isAttachMenuBotInstalled = false
                    }
                }
                
                let context = self.context
                if !noticed || botApp.flags.contains(.notActivated) || isAttachMenuBotInstalled == false {
                    if let isAttachMenuBotInstalled, let attachMenuBot {
                        if !isAttachMenuBotInstalled {
                            let controller = webAppTermsAlertController(context: context, updatedPresentationData: self.updatedPresentationData, bot: attachMenuBot, completion: { allowWrite in
                                let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                                let _ = (context.engine.messages.addBotToAttachMenu(botId: botPeer.id, allowWrite: allowWrite)
                                         |> deliverOnMainQueue).startStandalone(error: { _ in
                                }, completed: {
                                    openBotApp(allowWrite, true)
                                })
                            })
                            self.present(controller, in: .window(.root))
                        } else {
                            openBotApp(false, false)
                        }
                    } else {
                        let controller = webAppLaunchConfirmationController(context: context, updatedPresentationData: self.updatedPresentationData, peer: botPeer, requestWriteAccess: botApp.flags.contains(.notActivated) && botApp.flags.contains(.requiresWriteAccess), completion: { allowWrite in
                            let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                            openBotApp(allowWrite, false)
                        }, showMore: { [weak self] in
                            if let self {
                                self.openResolved(result: .peer(botPeer._asPeer(), .info(nil)), sourceMessageId: nil)
                            }
                        }, openTerms: { [weak self] in
                            if let self {
                                self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: self.presentationData.strings.WebApp_LaunchTermsConfirmation_URL, forceExternal: false, presentationData: self.presentationData, navigationController: self.effectiveNavigationController, dismissInput: {})
                            }
                        })
                        self.present(controller, in: .window(.root))
                    }
                } else {
                    openBotApp(false, false)
                }
            })
        } else {
            self.context.sharedContext.openWebApp(context: self.context, parentController: self, updatedPresentationData: self.updatedPresentationData, peer: botPeer, threadId: nil, buttonText: "", url: "", simple: true, source: .generic, skipTermsOfService: false, payload: payload)
        }
    }
}

//
//  NewsBlurAccountDelegate.swift
//  Account
//
//  Created by Anh-Quang Do on 3/9/20.
//  Copyright (c) 2020 Ranchero Software, LLC. All rights reserved.
//

import Articles
import RSCore
import RSDatabase
import RSParser
import RSWeb
import SyncDatabase
import os.log

final class NewsBlurAccountDelegate: AccountDelegate {

	var behaviors: AccountBehaviors = []

	var isOPMLImportInProgress: Bool = false
	var server: String? = "newsblur.com"
	var credentials: Credentials? {
		didSet {
			caller.credentials = credentials
		}
	}

	var accountMetadata: AccountMetadata? = nil
	var refreshProgress = DownloadProgress(numberOfTasks: 0)

	private let caller: NewsBlurAPICaller
	private let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "NewsBlur")
	private let database: SyncDatabase

	init(dataFolder: String, transport: Transport?) {
		if let transport = transport {
			caller = NewsBlurAPICaller(transport: transport)
		} else {
			let sessionConfiguration = URLSessionConfiguration.default
			sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
			sessionConfiguration.timeoutIntervalForRequest = 60.0
			sessionConfiguration.httpShouldSetCookies = false
			sessionConfiguration.httpCookieAcceptPolicy = .never
			sessionConfiguration.httpMaximumConnectionsPerHost = 1
			sessionConfiguration.httpCookieStorage = nil
			sessionConfiguration.urlCache = nil

			if let userAgentHeaders = UserAgent.headers() {
				sessionConfiguration.httpAdditionalHeaders = userAgentHeaders
			}

			let session = URLSession(configuration: sessionConfiguration)
			caller = NewsBlurAPICaller(transport: session)
		}

		database = SyncDatabase(databaseFilePath: dataFolder.appending("/DB.sqlite3"))
	}

	func refreshAll(for account: Account, completion: @escaping (Result<Void, Error>) -> ()) {
		self.refreshProgress.addToNumberOfTasksAndRemaining(5)

		refreshFeeds(for: account) { result in
			self.refreshProgress.completeTask()

			switch result {
			case .success:
				self.sendArticleStatus(for: account) { result in
					self.refreshProgress.completeTask()

					switch result {
					case .success:
						self.refreshArticleStatus(for: account) { result in
							self.refreshProgress.completeTask()

							switch result {
							case .success:
								self.refreshStories(for: account) { result in
									self.refreshProgress.completeTask()

									switch result {
									case .success:
										self.refreshMissingStories(for: account) { result in
											self.refreshProgress.completeTask()

											switch result {
											case .success:
												DispatchQueue.main.async {
													completion(.success(()))
												}

											case .failure(let error):
												completion(.failure(error))
											}
										}

									case .failure(let error):
										completion(.failure(error))
									}
								}

							case .failure(let error):
								completion(.failure(error))
							}
						}

					case .failure(let error):
						completion(.failure(error))
					}
				}

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func sendArticleStatus(for account: Account, completion: @escaping (Result<Void, Error>) -> ()) {
		os_log(.debug, log: log, "Sending story statuses...")

		database.selectForProcessing { result in

			func processStatuses(_ syncStatuses: [SyncStatus]) {
				let createUnreadStatuses = syncStatuses.filter { $0.key == ArticleStatus.Key.read && $0.flag == false }
				let deleteUnreadStatuses = syncStatuses.filter { $0.key == ArticleStatus.Key.read && $0.flag == true }
				let createStarredStatuses = syncStatuses.filter { $0.key == ArticleStatus.Key.starred && $0.flag == true }
				let deleteStarredStatuses = syncStatuses.filter { $0.key == ArticleStatus.Key.starred && $0.flag == false }

				let group = DispatchGroup()
				var errorOccurred = false

				group.enter()
				self.sendStoryStatuses(createUnreadStatuses, throttle: true, apiCall: self.caller.markAsUnread) { result in
					group.leave()
					if case .failure = result {
						errorOccurred = true
					}
				}

				group.enter()
				self.sendStoryStatuses(deleteUnreadStatuses, throttle: false, apiCall: self.caller.markAsRead) { result in
					group.leave()
					if case .failure = result {
						errorOccurred = true
					}
				}

				group.enter()
				self.sendStoryStatuses(createStarredStatuses, throttle: true, apiCall: self.caller.star) { result in
					group.leave()
					if case .failure = result {
						errorOccurred = true
					}
				}

				group.enter()
				self.sendStoryStatuses(deleteStarredStatuses, throttle: true, apiCall: self.caller.unstar) { result in
					group.leave()
					if case .failure = result {
						errorOccurred = true
					}
				}

				group.notify(queue: DispatchQueue.main) {
					os_log(.debug, log: self.log, "Done sending article statuses.")
					if errorOccurred {
						completion(.failure(NewsBlurError.unknown))
					} else {
						completion(.success(()))
					}
				}
			}

			switch result {
			case .success(let syncStatuses):
				processStatuses(syncStatuses)
			case .failure(let databaseError):
				completion(.failure(databaseError))
			}
		}
	}

	func refreshArticleStatus(for account: Account, completion: @escaping (Result<Void, Error>) -> ()) {
		os_log(.debug, log: log, "Refreshing story statuses...")

		let group = DispatchGroup()
		var errorOccurred = false

		group.enter()
		caller.retrieveUnreadStoryHashes { result in
			switch result {
			case .success(let storyHashes):
				self.syncStoryReadState(account: account, hashes: storyHashes)
				group.leave()
			case .failure(let error):
				errorOccurred = true
				os_log(.info, log: self.log, "Retrieving unread stories failed: %@.", error.localizedDescription)
				group.leave()
			}
		}

		group.enter()
		caller.retrieveStarredStoryHashes { result in
			switch result {
			case .success(let storyHashes):
				self.syncStoryStarredState(account: account, hashes: storyHashes)
				group.leave()
			case .failure(let error):
				errorOccurred = true
				os_log(.info, log: self.log, "Retrieving starred stories failed: %@.", error.localizedDescription)
				group.leave()
			}
		}

		group.notify(queue: DispatchQueue.main) {
			os_log(.debug, log: self.log, "Done refreshing article statuses.")
			if errorOccurred {
				completion(.failure(NewsBlurError.unknown))
			} else {
				completion(.success(()))
			}
		}
	}

	func refreshStories(for account: Account, completion: @escaping (Result<Void, Error>) -> Void) {
		os_log(.debug, log: log, "Refreshing stories...")
		os_log(.debug, log: log, "Refreshing unread stories...")

		caller.retrieveUnreadStoryHashes { result in
			switch result {
			case .success(let storyHashes):
				self.refreshProgress.completeTask()

				self.refreshUnreadStories(for: account, hashes: storyHashes, updateFetchDate: nil, completion: completion)
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func refreshMissingStories(for account: Account, completion: @escaping (Result<Void, Error>)-> Void) {
		completion(.success(()))
	}
	
	func processStories(account: Account, stories: [NewsBlurStory]?, completion: @escaping DatabaseCompletionBlock) {
		let parsedItems = mapStoriesToParsedItems(stories: stories)
		let webFeedIDsAndItems = Dictionary(grouping: parsedItems, by: { item in item.feedURL } ).mapValues { Set($0) }
		account.update(webFeedIDsAndItems: webFeedIDsAndItems, defaultRead: true, completion: completion)
	}

	func importOPML(for account: Account, opmlFile: URL, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func addFolder(for account: Account, name: String, completion: @escaping (Result<Folder, Error>) -> ()) {
	}

	func renameFolder(for account: Account, with folder: Folder, to name: String, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func removeFolder(for account: Account, with folder: Folder, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func createWebFeed(for account: Account, url: String, name: String?, container: Container, completion: @escaping (Result<WebFeed, Error>) -> ()) {
	}

	func renameWebFeed(for account: Account, with feed: WebFeed, to name: String, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func addWebFeed(for account: Account, with: WebFeed, to container: Container, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func removeWebFeed(for account: Account, with feed: WebFeed, from container: Container, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func moveWebFeed(for account: Account, with feed: WebFeed, from: Container, to: Container, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func restoreWebFeed(for account: Account, feed: WebFeed, container: Container, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func restoreFolder(for account: Account, folder: Folder, completion: @escaping (Result<Void, Error>) -> ()) {
		completion(.success(()))
	}

	func markArticles(for account: Account, articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool) -> Set<Article>? {
		let syncStatuses = articles.map { article in
			return SyncStatus(articleID: article.articleID, key: statusKey, flag: flag)
		}
		database.insertStatuses(syncStatuses)

		database.selectPendingCount { result in
			if let count = try? result.get(), count > 100 {
				self.sendArticleStatus(for: account) { _ in }
			}
		}

		return try? account.update(articles, statusKey: statusKey, flag: flag)
	}

	func accountDidInitialize(_ account: Account) {
		credentials = try? account.retrieveCredentials(type: .newsBlurSessionId)
	}

	func accountWillBeDeleted(_ account: Account) {
		caller.logout() { _ in }
	}

	class func validateCredentials(transport: Transport, credentials: Credentials, endpoint: URL? = nil, completion: @escaping (Result<Credentials?, Error>) -> ()) {
		let caller = NewsBlurAPICaller(transport: transport)
		caller.credentials = credentials
		caller.validateCredentials() { result in
			DispatchQueue.main.async {
				completion(result)
			}
		}
	}

	// MARK: Suspend and Resume (for iOS)

	/// Suspend all network activity
	func suspendNetwork() {
		caller.suspend()
	}

	/// Suspend the SQLLite databases
	func suspendDatabase() {
		database.suspend()
	}

	/// Make sure no SQLite databases are open and we are ready to issue network requests.
	func resume() {
		caller.resume()
		database.resume()
	}
}

extension NewsBlurAccountDelegate {
	private func refreshFeeds(for account: Account, completion: @escaping (Result<Void, Error>) -> Void) {
		os_log(.debug, log: log, "Refreshing feeds...")

		caller.retrieveFeeds { result in
			switch result {
			case .success((let feeds, let folders)):
				BatchUpdate.shared.perform {
					self.syncFolders(account, folders)
					self.syncFeeds(account, feeds)
					self.syncFeedFolderRelationship(account, folders)
				}

				self.refreshProgress.completeTask()
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	private func syncFolders(_ account: Account, _ folders: [NewsBlurFolder]?) {
		guard let folders = folders else { return }
		assert(Thread.isMainThread)

		os_log(.debug, log: log, "Syncing folders with %ld folders.", folders.count)

		let folderNames = folders.map { $0.name }

		// Delete any folders not at NewsBlur
		if let folders = account.folders {
			folders.forEach { folder in
				if !folderNames.contains(folder.name ?? "") {
					for feed in folder.topLevelWebFeeds {
						account.addWebFeed(feed)
						clearFolderRelationship(for: feed, withFolderName: folder.name ?? "")
					}
					account.removeFolder(folder)
				}
			}
		}

		let accountFolderNames: [String] =  {
			if let folders = account.folders {
				return folders.map { $0.name ?? "" }
			} else {
				return [String]()
			}
		}()

		// Make any folders NewsBlur has, but we don't
		folderNames.forEach { folderName in
			if !accountFolderNames.contains(folderName) {
				_ = account.ensureFolder(with: folderName)
			}
		}
	}

	private func syncFeeds(_ account: Account, _ feeds: [NewsBlurFeed]?) {
		guard let feeds = feeds else { return }
		assert(Thread.isMainThread)

		os_log(.debug, log: log, "Syncing feeds with %ld feeds.", feeds.count)

		let subFeedIds = feeds.map { String($0.feedID) }

		// Remove any feeds that are no longer in the subscriptions
		if let folders = account.folders {
			for folder in folders {
				for feed in folder.topLevelWebFeeds {
					if !subFeedIds.contains(feed.webFeedID) {
						folder.removeWebFeed(feed)
					}
				}
			}
		}

		for feed in account.topLevelWebFeeds {
			if !subFeedIds.contains(feed.webFeedID) {
				account.removeWebFeed(feed)
			}
		}

		// Add any feeds we don't have and update any we do
		var feedsToAdd = Set<NewsBlurFeed>()
		feeds.forEach { feed in
			let subFeedId = String(feed.feedID)

			if let webFeed = account.existingWebFeed(withWebFeedID: subFeedId) {
				webFeed.name = feed.name
				// If the name has been changed on the server remove the locally edited name
				webFeed.editedName = nil
				webFeed.homePageURL = feed.homepageURL
				webFeed.subscriptionID = String(feed.feedID)
				webFeed.faviconURL = feed.faviconURL
			}
			else {
				feedsToAdd.insert(feed)
			}
		}

		// Actually add feeds all in one go, so we don’t trigger various rebuilding things that Account does.
		feedsToAdd.forEach { feed in
			let webFeed = account.createWebFeed(with: feed.name, url: feed.feedURL, webFeedID: String(feed.feedID), homePageURL: feed.homepageURL)
			webFeed.subscriptionID = String(feed.feedID)
			account.addWebFeed(webFeed)
		}
	}

	private func syncFeedFolderRelationship(_ account: Account, _ folders: [NewsBlurFolder]?) {
		guard let folders = folders else { return }
		assert(Thread.isMainThread)

		os_log(.debug, log: log, "Syncing folders with %ld folders.", folders.count)

		// Set up some structures to make syncing easier
		let relationships = folders.map({ $0.asRelationships }).flatMap { $0 }
		let folderDict = nameToFolderDictionary(with: account.folders)
		let foldersDict = relationships.reduce([String: [NewsBlurFolderRelationship]]()) { (dict, relationship) in
			var feedInFolders = dict
			if var feedInFolder = feedInFolders[relationship.folderName] {
				feedInFolder.append(relationship)
				feedInFolders[relationship.folderName] = feedInFolder
			} else {
				feedInFolders[relationship.folderName] = [relationship]
			}
			return feedInFolders
		}

		// Sync the folders
		for (folderName, folderRelationships) in foldersDict {
			guard let folder = folderDict[folderName] else { return }

			let folderFeedIDs = folderRelationships.map { String($0.feedID) }

			// Move any feeds not in the folder to the account
			for feed in folder.topLevelWebFeeds {
				if !folderFeedIDs.contains(feed.webFeedID) {
					folder.removeWebFeed(feed)
					clearFolderRelationship(for: feed, withFolderName: folder.name ?? "")
					account.addWebFeed(feed)
				}
			}

			// Add any feeds not in the folder
			let folderFeedIds = folder.topLevelWebFeeds.map { $0.webFeedID }

			for relationship in folderRelationships {
				let folderFeedID = String(relationship.feedID)
				if !folderFeedIds.contains(folderFeedID) {
					guard let feed = account.existingWebFeed(withWebFeedID: folderFeedID) else {
						continue
					}
					saveFolderRelationship(for: feed, withFolderName: folderName, id: relationship.folderName)
					folder.addWebFeed(feed)
				}
			}

		}

		let folderFeedIDs = Set(relationships.map { String($0.feedID) })

		// Remove all feeds from the account container that have a tag
		for feed in account.topLevelWebFeeds {
			if folderFeedIDs.contains(feed.webFeedID) {
				account.removeWebFeed(feed)
			}
		}
	}

	private func clearFolderRelationship(for feed: WebFeed, withFolderName folderName: String) {
		if var folderRelationship = feed.folderRelationship {
			folderRelationship[folderName] = nil
			feed.folderRelationship = folderRelationship
		}
	}

	private func saveFolderRelationship(for feed: WebFeed, withFolderName folderName: String, id: String) {
		if var folderRelationship = feed.folderRelationship {
			folderRelationship[folderName] = id
			feed.folderRelationship = folderRelationship
		} else {
			feed.folderRelationship = [folderName: id]
		}
	}

	private func nameToFolderDictionary(with folders: Set<Folder>?) -> [String: Folder] {
		guard let folders = folders else {
			return [String: Folder]()
		}

		var d = [String: Folder]()
		for folder in folders {
			let name = folder.name ?? ""
			if d[name] == nil {
				d[name] = folder
			}
		}
		return d
	}

	private func refreshUnreadStories(for account: Account, hashes: [NewsBlurStoryHash]?, updateFetchDate: Date?, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let hashes = hashes, !hashes.isEmpty else {
			if let lastArticleFetch = updateFetchDate {
				self.accountMetadata?.lastArticleFetchStartTime = lastArticleFetch
				self.accountMetadata?.lastArticleFetchEndTime = Date()
			}
			completion(.success(()))
			return
		}

		let numberOfStories = min(hashes.count, 100) // api limit
		let hashesToFetch = Array(hashes[..<numberOfStories])

		caller.retrieveStories(hashes: hashesToFetch) { result in
			switch result {
			case .success(let stories):
				self.processStories(account: account, stories: stories) { error in
					self.refreshProgress.completeTask()

					if let error = error {
						completion(.failure(error))
						return
					}

					self.refreshUnreadStories(for: account, hashes: Array(hashes[numberOfStories...]), updateFetchDate: updateFetchDate) { result in
						os_log(.debug, log: self.log, "Done refreshing stories.")
						switch result {
						case .success:
							completion(.success(()))
						case .failure(let error):
							completion(.failure(error))
						}
					}
				}
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	private func mapStoriesToParsedItems(stories: [NewsBlurStory]?) -> Set<ParsedItem> {
		guard let stories = stories else { return Set<ParsedItem>() }

		let parsedItems: [ParsedItem] = stories.map { story in
			let author = Set([ParsedAuthor(name: story.authorName, url: nil, avatarURL: nil, emailAddress: nil)])
			return ParsedItem(syncServiceID: story.storyID, uniqueID: String(story.storyID), feedURL: String(story.feedID), url: story.url, externalURL: nil, title: story.title, contentHTML: story.contentHTML, contentText: nil, summary: nil, imageURL: nil, bannerImageURL: nil, datePublished: story.datePublished, dateModified: nil, authors: author, tags: nil, attachments: nil)
		}

		return Set(parsedItems)
	}

	private func sendStoryStatuses(_ statuses: [SyncStatus],
								   throttle: Bool,
								   apiCall: ([String], @escaping (Result<Void, Error>) -> Void) -> Void,
								   completion: @escaping (Result<Void, Error>) -> Void) {
		guard !statuses.isEmpty else {
			completion(.success(()))
			return
		}

		let group = DispatchGroup()
		var errorOccurred = false

		let storyHashes = statuses.compactMap { $0.articleID }
		let storyHashGroups = storyHashes.chunked(into: throttle ? 1 : 5) // api limit
		for storyHashGroup in storyHashGroups {
			group.enter()
			apiCall(storyHashGroup) { result in
				switch result {
				case .success:
					self.database.deleteSelectedForProcessing(storyHashGroup.map { String($0) } )
					group.leave()
				case .failure(let error):
					errorOccurred = true
					os_log(.error, log: self.log, "Story status sync call failed: %@.", error.localizedDescription)
					self.database.resetSelectedForProcessing(storyHashGroup.map { String($0) } )
					group.leave()
				}
			}
		}

		group.notify(queue: DispatchQueue.main) {
			if errorOccurred {
				completion(.failure(NewsBlurError.unknown))
			} else {
				completion(.success(()))
			}
		}
	}

	private func syncStoryReadState(account: Account, hashes: [NewsBlurStoryHash]?) {
		guard let hashes = hashes else { return }

		database.selectPendingReadStatusArticleIDs() { result in
			func process(_ pendingStoryHashes: Set<String>) {

				let newsBlurUnreadStoryHashes = Set(hashes.map { $0.hash } )
				let updatableNewsBlurUnreadStoryHashes = newsBlurUnreadStoryHashes.subtracting(pendingStoryHashes)

				account.fetchUnreadArticleIDs { articleIDsResult in
					guard let currentUnreadArticleIDs = try? articleIDsResult.get() else {
						return
					}

					// Mark articles as unread
					let deltaUnreadArticleIDs = updatableNewsBlurUnreadStoryHashes.subtracting(currentUnreadArticleIDs)
					account.markAsUnread(deltaUnreadArticleIDs)

					// Mark articles as read
					let deltaReadArticleIDs = currentUnreadArticleIDs.subtracting(updatableNewsBlurUnreadStoryHashes)
					account.markAsRead(deltaReadArticleIDs)
				}
			}

			switch result {
			case .success(let pendingArticleIDs):
				process(pendingArticleIDs)
			case .failure(let error):
				os_log(.error, log: self.log, "Sync Story Read Status failed: %@.", error.localizedDescription)
			}
		}
	}

	private func syncStoryStarredState(account: Account, hashes: [NewsBlurStoryHash]?) {
		guard let hashes = hashes else { return }

		database.selectPendingStarredStatusArticleIDs() { result in
			func process(_ pendingStoryHashes: Set<String>) {

				let newsBlurStarredStoryHashes = Set(hashes.map { $0.hash } )
				let updatableNewsBlurUnreadStoryHashes = newsBlurStarredStoryHashes.subtracting(pendingStoryHashes)

				account.fetchStarredArticleIDs { articleIDsResult in
					guard let currentStarredArticleIDs = try? articleIDsResult.get() else {
						return
					}

					// Mark articles as starred
					let deltaStarredArticleIDs = updatableNewsBlurUnreadStoryHashes.subtracting(currentStarredArticleIDs)
					account.markAsStarred(deltaStarredArticleIDs)

					// Mark articles as unstarred
					let deltaUnstarredArticleIDs = currentStarredArticleIDs.subtracting(updatableNewsBlurUnreadStoryHashes)
					account.markAsUnstarred(deltaUnstarredArticleIDs)
				}
			}

			switch result {
			case .success(let pendingArticleIDs):
				process(pendingArticleIDs)
			case .failure(let error):
				os_log(.error, log: self.log, "Sync Story Starred Status failed: %@.", error.localizedDescription)
			}
		}
	}
}

//
//  Article+Scriptability.swift
//  NetNewsWire
//
//  Created by Olof Hellman on 1/23/18.
//  Copyright © 2018 Olof Hellman. All rights reserved.
//

import Foundation
import Account
import Articles

@objc(ScriptableArticle)
final class ScriptableArticle: NSObject, UniqueIdScriptingObject, ScriptingObjectContainer {

    let article: Article
    let container: ScriptingObjectContainer

    init (_ article: Article, container: ScriptingObjectContainer) {
        self.article = article
        self.container = container
    }

    @objc(objectSpecifier)
    override var objectSpecifier: NSScriptObjectSpecifier? {
        let scriptObjectSpecifier = self.container.makeFormUniqueIDScriptObjectSpecifier(forObject: self)
        return (scriptObjectSpecifier)
    }

    // MARK: --- ScriptingObject protocol ---

    var scriptingKey: String {
        return "articles"
    }

    // MARK: --- UniqueIdScriptingObject protocol ---

    // articles have id in the NetNewsWire database and id in the feed
    // article.uniqueID here is the feed unique id

    @objc(uniqueId)
    var scriptingUniqueId: Any {
        return article.uniqueID
    }

    // MARK: --- ScriptingObjectContainer protocol ---

    var scriptingClassDescription: NSScriptClassDescription {
        return self.classDescription as! NSScriptClassDescription
    }

    func deleteElement(_ element: ScriptingObject) {
        print("delete event not handled")
    }

    // MARK: --- Scriptable properties ---

    @objc(url)
    var url: String? {
        return article.preferredLink
    }

    @objc(permalink)
    var permalink: String? {
        return article.link
    }

    @objc(externalUrl)
    var externalUrl: String? {
        return article.externalLink
    }

    @objc(title)
    var title: String {
        return article.title ?? ""
    }

    @objc(contents)
    var contents: String {
        return article.contentText ?? ""
    }

    @objc(html)
    var html: String {
        return article.contentHTML ?? ""
    }

    @objc(summary)
    var summary: String {
        return article.summary ?? ""
    }

    @objc(datePublished)
    var datePublished: Date? {
        return article.datePublished
    }

    @objc(dateModified)
    var dateModified: Date? {
        return article.dateModified
    }

    @objc(dateArrived)
    var dateArrived: Date {
        return article.status.dateArrived
    }

    @objc(read)
    var read: Bool {
		get {
			return article.status.boolStatus(forKey: .read)
		}
		set {
			markArticles([self.article], statusKey: .read, flag: newValue)
		}
    }

    @objc(starred)
    var starred: Bool {
		get {
			return article.status.boolStatus(forKey: .starred)
		}
		set {
			markArticles([self.article], statusKey: .starred, flag: newValue)
		}
    }

    @objc(deleted)
    var deleted: Bool {
        return false
    }

    @objc(imageURL)
    var imageURL: String {
        return article.imageLink ?? ""
    }

    @objc(authors)
    var authors: NSArray {
        let articleAuthors = article.authors ?? []
        return articleAuthors.map { ScriptableAuthor($0, container: self) } as NSArray
    }

	@objc(feed)
	var feed: ScriptableFeed? {
		guard let parentFeed = self.article.feed,
			let account = parentFeed.account
			else { return nil }

		return ScriptableFeed(parentFeed, container: ScriptableAccount(account))
	}

}

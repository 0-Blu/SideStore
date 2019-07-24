//
//  AppManager.swift
//  AltStore
//
//  Created by Riley Testut on 5/29/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import UIKit

import AltSign
import AltKit

import Roxas

extension AppManager
{
    static let didFetchAppsNotification = Notification.Name("com.altstore.AppManager.didFetchApps")
}

class AppManager
{
    static let shared = AppManager()
    
    private let operationQueue = OperationQueue()
    private let processingQueue = DispatchQueue(label: "com.altstore.AppManager.processingQueue")
    
    private var installationProgress = [String: Progress]()
    private var refreshProgress = [String: Progress]()
    
    private init()
    {
        self.operationQueue.name = "com.altstore.AppManager.operationQueue"
    }
}

extension AppManager
{
    func update()
    {
        #if targetEnvironment(simulator)
        // Apps aren't ever actually installed to simulator, so just do nothing rather than delete them from database.
        return
        #else
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundSavingViewContext()
        
        let fetchRequest = InstalledApp.fetchRequest() as NSFetchRequest<InstalledApp>
        fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(InstalledApp.app)]
        
        do
        {
            let installedApps = try context.fetch(fetchRequest)
            for app in installedApps
            {
                if UIApplication.shared.canOpenURL(app.openAppURL)
                {
                    // App is still installed, good!
                }
                else
                {
                    context.delete(app)
                }
            }
            
            try context.save()
        }
        catch
        {
            print("Error while fetching installed apps")
        }
        
        #endif
    }
    
    func authenticate(presentingViewController: UIViewController?, completionHandler: @escaping (Result<ALTSigner, Error>) -> Void)
    {
        let authenticationOperation = AuthenticationOperation(presentingViewController: presentingViewController)
        authenticationOperation.resultHandler = { (result) in
            completionHandler(result)
        }
        self.operationQueue.addOperation(authenticationOperation)
    }
}

extension AppManager
{
    func fetchApps(completionHandler: @escaping (Result<[App], Error>) -> Void)
    {
        let fetchAppsOperation = FetchAppsOperation()
        fetchAppsOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                completionHandler(.failure(error))
                
            case .success(let apps):
                completionHandler(.success(apps))
                NotificationCenter.default.post(name: AppManager.didFetchAppsNotification, object: self)
            }
        }
        self.operationQueue.addOperation(fetchAppsOperation)
    }
}

extension AppManager
{
    func install(_ app: App, presentingViewController: UIViewController, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        if let progress = self.installationProgress(for: app)
        {
            return progress
        }
        
        let appIdentifier = app.identifier
        
        let group = self.install([app], forceDownload: true, presentingViewController: presentingViewController)
        group.completionHandler = { (result) in            
            do
            {
                self.installationProgress[appIdentifier] = nil
                
                guard let (_, result) = try result.get().first else { throw OperationError.unknown }
                completionHandler(result)
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        self.installationProgress[app.identifier] = group.progress
        
        return group.progress
    }
    
    func refresh(_ installedApps: [InstalledApp], presentingViewController: UIViewController?, group: OperationGroup? = nil) -> OperationGroup
    {
        let apps = installedApps.compactMap { $0.app }.filter { self.refreshProgress(for: $0) == nil }

        let group = self.install(apps, forceDownload: false, presentingViewController: presentingViewController, group: group)
        
        for app in apps
        {
            guard let progress = group.progress(for: app) else { continue }
            self.refreshProgress[app.identifier] = progress
        }
        
        return group
    }
    
    func installationProgress(for app: App) -> Progress?
    {
        let progress = self.installationProgress[app.identifier]
        return progress
    }
    
    func refreshProgress(for app: App) -> Progress?
    {
        let progress = self.refreshProgress[app.identifier]
        return progress
    }
}

private extension AppManager
{
    func install(_ apps: [App], forceDownload: Bool, presentingViewController: UIViewController?, group: OperationGroup? = nil) -> OperationGroup
    {
        // Authenticate -> Download (if necessary) -> Resign -> Send -> Install.
        let group = group ?? OperationGroup()
        
        guard let server = ServerManager.shared.discoveredServers.first else {
            DispatchQueue.main.async {
                group.completionHandler?(.failure(ConnectionError.serverNotFound))
            }
            
            return group
        }
        
        group.server = server
        
        var operations = [Operation]()
        
        
        /* Authenticate */
        let authenticationOperation = AuthenticationOperation(presentingViewController: presentingViewController)
        authenticationOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): group.error = error
            case .success(let signer): group.signer = signer
            }
        }
        operations.append(authenticationOperation)
        
        
        for app in apps
        {
            let context = AppOperationContext(appIdentifier: app.identifier, group: group)
            let progress = Progress.discreteProgress(totalUnitCount: 100)
            
            
            /* Resign */
            let resignAppOperation = ResignAppOperation(context: context)
            resignAppOperation.resultHandler = { (result) in
                guard let fileURL = self.process(result, context: context) else { return }
                context.resignedFileURL = fileURL
            }
            resignAppOperation.addDependency(authenticationOperation)
            progress.addChild(resignAppOperation.progress, withPendingUnitCount: 20)
            operations.append(resignAppOperation)
            
            
            /* Download */
            let fileURL = InstalledApp.fileURL(for: app)
            if let installedApp = app.installedApp, FileManager.default.fileExists(atPath: fileURL.path), !forceDownload
            {
                // Already installed, don't need to download.
                
                // If we don't need to download the app, reduce the total unit count by 40.
                progress.totalUnitCount -= 40
                
                let backgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
                backgroundContext.performAndWait {
                    let installedApp = backgroundContext.object(with: installedApp.objectID) as! InstalledApp
                    context.installedApp = installedApp
                }
            }
            else
            {
                // App is not yet installed (or we're forcing it to download a new version), so download it before resigning it.
                
                let downloadOperation = DownloadAppOperation(app: app)
                downloadOperation.resultHandler = { (result) in
                    guard let installedApp = self.process(result, context: context) else { return }
                    context.installedApp = installedApp
                }
                progress.addChild(downloadOperation.progress, withPendingUnitCount: 40)
                resignAppOperation.addDependency(downloadOperation)
                operations.append(downloadOperation)
            }
            
            
            /* Send */
            let sendAppOperation = SendAppOperation(context: context)
            sendAppOperation.resultHandler = { (result) in
                guard let connection = self.process(result, context: context) else { return }
                context.connection = connection
            }
            progress.addChild(sendAppOperation.progress, withPendingUnitCount: 10)
            sendAppOperation.addDependency(resignAppOperation)
            operations.append(sendAppOperation)
            
            
            /* Install */
            let installOperation = InstallAppOperation(context: context)
            installOperation.resultHandler = { (result) in
                if let error = result.error
                {
                    context.error = error
                }
                
                self.finishAppOperation(context) // Finish operation no matter what.
            }
            progress.addChild(installOperation.progress, withPendingUnitCount: 30)
            installOperation.addDependency(sendAppOperation)
            operations.append(installOperation)
                        
            group.set(progress, for: app)
        }
        
        group.addOperations(operations)
        
        return group
    }
    
    @discardableResult func process<T>(_ result: Result<T, Error>, context: AppOperationContext) -> T?
    {
        do
        {            
            let value = try result.get()
            return value
        }
        catch OperationError.cancelled
        {
            context.error = OperationError.cancelled
            self.finishAppOperation(context)
            
            return nil
        }
        catch
        {
            context.error = error
            return nil
        }
    }
    
    func finishAppOperation(_ context: AppOperationContext)
    {
        self.processingQueue.sync {
            guard !context.isFinished else { return }
            context.isFinished = true
            
            if let error = context.error
            {
                context.group.results[context.appIdentifier] = .failure(error)
            }
            else if let installedApp = context.installedApp
            {
                context.group.results[context.appIdentifier] = .success(installedApp)
                
                // Save after each installation.
                installedApp.managedObjectContext?.performAndWait {
                    do { try installedApp.managedObjectContext?.save() }
                    catch { print("Error saving installed app.", error) }
                }
            }
            
            self.refreshProgress[context.appIdentifier] = nil
            
            print("Finished operation!", context.appIdentifier)

            if context.group.results.count == context.group.progress.totalUnitCount
            {
                context.group.completionHandler?(.success(context.group.results))
            }
        }
    }
}

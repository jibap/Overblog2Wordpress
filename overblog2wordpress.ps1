$xml = New-Object -TypeName XML
$xml.Load("export_over-blog.xml") ## Saisir ici le nom du fichier d'export généré par Overblog

## Suppression du noeud "blog"
$xml.root.SelectNodes("blog") | %{$_.ParentNode.RemoveChild($_)} | Out-Null

$statusArray = @("","draft","publish")

$id = 5847 ## Saisir ici le dernier ID de posts en base >> SELECT ID FROM `wp_posts` ORDER BY ID DESC LIMIT 1

## Pré-création du XML de commentaires
$xmlComments = New-Object -TypeName XML
$xmldecl = $xmlComments.CreateXmlDeclaration("1.0","UTF-8",$null)
$xmlComments.AppendChild($xmldecl) | out-null
$xmlroot = $xmlComments.CreateNode("element","comments",$null)
$xmlComments.AppendChild($xmlroot) | out-null

# URL de l'image de remplacement par défaut (à importer avant dans votre médiathèque WP)
$placeholderIMG = "https://cooklicot.fr/blog/wp-content/uploads/2022/01/placeholder.png"


function cleanHTML($nodeElement){
    $nodeContent = $nodeElement.innerXml

    # Suppression des mauvaises balises </img>
    $nodeContent = $nodeContent -replace '(?s)</img>'

    # Suppression des balises CDATA pour la commande suivante qui ne fonctionnerait pas sinon
    $nodeContent = $nodeContent -replace '(?s)^<!\[CDATA\[(.*)]]>$', '$1'

    # La commande suivante nécessite une lib : Install-Module PSParseHTML -AllowClobber -Force
    # Optimize va nettoyer le code pour avoir du HTML propre
    $nodeContent = Optimize-HTML -content $nodeContent
    # Reformatage HTML sinon les quotes sont supprimées et plus rien ne marche...
    $nodeContent = Format-HTML -content $nodeContent

    # Suppression des espaces vides (sinon les regex ne trouve pas tout)
    $nodeContent = [regex]::Replace($nodeContent, '(?s)\s\s+', '')

    # Remplacement des balises <html><body> ajoutées par le optimize par les balises CDATA suprimmées précédemment
    $nodeContent = $nodeContent -replace '(?s)^<html><body>(.*)<\/body>\n<\/html>$', '<![CDATA[$1]]>'    

    # Enregistrement XML
    $nodeElement.innerXml = $nodeContent
}

function checkURLs($nodeElement){
    $nodeContent = $nodeElement.innerXml

    # Récupération des URL des images dans le contenu
    $imgTags = Select-String -input $nodeContent -Pattern '(?s)<img.+?src="([^"]*)"[^>]*>' -AllMatches
    $badImagesCount = 0
    foreach($imgTag in $imgTags.Matches){
        $urlImage = $imgTag.Groups[1].value
        # Vérifie la joignabilité de l'image 
        if($urlImage.length -cgt 1){# EXCEPTION URL vides ou # (gagne du temps)
           try {
              $ProgressPreference = 'SilentlyContinue'
              Invoke-WebRequest -Uri $urlImage -TimeoutSec 5 | Out-Null
           } 
           catch [System.Net.WebException] {
              $badImagesCount++
              # remplacement des images injoignable par l'image par défaut ($placeholderIMG)
              $nodeContent = [regex]::Replace($nodeContent, [Regex]::Escape($imgTag.value), '<img src="'+ $placeholderIMG +'" />')
              Add-Content bad_images_generation.txt "$urlImage`n"
           }
        }else{
            # L'URL n'est pas correcte (vide ou #), remplacement par l'image par défaut ($placeholderIMG)
            $badImagesCount++
            $nodeContent = [regex]::Replace($nodeContent, [Regex]::Escape($imgTag.value), '<img src="'+ $placeholderIMG +'" />')
        }
    }
    # Enregistrement XML
    $nodeElement.innerXml = $nodeContent
    if($badImagesCount){write-host "`t`t Image(s) injoignable(s) :" $badImagesCount -ForegroundColor Red}
}

function removeLinks($nodeElement){
    $nodeContent = $nodeElement.innerXml
    
    # Extraction des balises <a> qui contiennent une image et récupération des 2 URLs
    $aTags = Select-String -input $nodeContent -pattern '(?s)<a[^>]*href="([^"]*)"[^>]*>(<img.+?src="([^"]*)"[^>]*>)<\/a>' -AllMatches
    # Parcours des balises trouvées
    foreach($aTag in $aTags.Matches){
        $removeLink = 0
        $href = $aTag.groups[1].value
        $imgTag = $aTag.groups[2].value
        $src = $aTag.groups[3].value

        # Si l'URL de l'image est la même que le lien
        if($src -eq $href){
            # On retrouve le match complet et on remplace par l'image seule
            # Pour exemple ...$pattern = '(?s)<a[^>]*href="' + [regex]::escape($href) + '"[^>]*><img.*?src="' + [regex]::escape($src) + '"[^>]*><\/a>'
            $removeLink = 1
        }else{
            # si upscale() dans l'URL de l'image        
            if($src -match 'no_upscale\(\)'){
                # Extraction du nom du fichier de l'image 
                $imgFileNameMatch = Select-String -input $src -pattern '(?s)%2F([^%]*)$'
                # Si gabarit classique OverBlog (%2Fnom_fichier.ext), trop compliqué pour les autres...
                if($imgFileNameMatch.Matches.Success){
                    $imgFileName = $imgFileNameMatch.Matches.Groups[1].value

                    # Vérifie si le nom du fichier est dans le lien ?
                    if($href -match $imgFileName){
                        $removeLink = 1
                    }
                }
            }
        }
        # Suppression du lien puisqu'il pointe vers l'image (directement ou via redim OB) !
        if($removeLink){
            # On retrouve le match complet et on remplace par l'image seule  
            $nodeContent = [regex]::Replace($nodeContent, [Regex]::Escape($aTag.Value), $imgTag)
        }
    }
    # Enregistrement XML
    $nodeElement.innerXml = $nodeContent
}

function removeClass($nodeElement){
    $nodeElement.innerXml = $nodeElement.innerXml -replace ' class="[^"]*"'
}

function extractComments($commentsNode){
    if($commentsNode.comment){## S'il y a des réponses au commentaire
        Foreach($comment in $commentsNode.comment){
            # Copie du noeud des commentaires
            $clone = $xmlComments.ImportNode($comment.clone(), $true) 
           
            # suppression des noeuds inutiles
            $clone.SelectNodes("author_url") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
            $clone.SelectNodes("author_ip") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
            $clone.SelectNodes("status") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
           
            # Ajout de l'ID du post parent
            $postId = $xmlComments.CreateElement('post_id')
            $postId.InnerText = $script:id
            $clone.AppendChild($postId) | Out-Null
           
            # Ajout de la date du commentaire parent
            $parentNode = $comment.ParentNode.ParentNode
            if($parentNode.Name -eq "comment"){ # pour les commentaires de premier niveau le parent est un post
                $parentDate = $xmlComments.CreateElement('parent_date')
                $parentDate.InnerText = $parentNode.published_at
                $clone.AppendChild($parentDate) | Out-Null
            }
            # ajout du commentaire au XML dédié
            $xmlComments.DocumentElement.AppendChild($clone) | Out-Null
           
            # Fonction récursive pour récupérer toutes les réponses
            extractComments($clone.replies)            
        }
    }
}


function tranform($node){
    $script:id++

    write-host "`t" $node.title

    # Suppression des noeuds inutiles
    $node.SelectNodes("origin") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
    $node.SelectNodes("slug") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
    $node.SelectNodes("created_at") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
    $node.SelectNodes("modified_at") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
    $node.SelectNodes("author") | %{$_.ParentNode.RemoveChild($_)} | Out-Null

    #Minify HTML content
    cleanHTML($node.content)
    
    # suppression des attributs "class"
    removeClass($node.content)

    # suppression des liens sur images
    removeLinks($node.content)

    # Vérification des images obsolètes
    checkURLs($node.content)

    # Transposition des status
    $node.status = $statusArray[$node.status]
    
    # Ajout d'un noeud pour avoir un ID unique (servira après pour mapper les commentaires)
    $nodeId = $xml.CreateElement('import_id')
    $nodeId.InnerText = $script:id
    $node.AppendChild($nodeId) | Out-Null
    
    # Extraction des commentaires
    extractComments($node.comments)

    # Nettoyage des commentaires inutiles dans l'objet puisque extraits
    $node.SelectNodes("comments") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
}

# START #
cls
## Boucle sur les articles  
$counter = 0
$countArticles = $xml.root.posts.post.count
$currentDT = Get-Date -Format "dd/MM/yyyy hh:mm:ss"
write-host "Traitement des articles : $currentDT" -ForegroundColor Yellow
Foreach ($post in $xml.root.posts.post){
    $counter++
    Write-Progress -Activity "Articles" -Status "$counter / $countArticles" -PercentComplete (($counter*100)/$countArticles)
    tranform($post)
}


## Boucle sur les pages
$counter = 0
$countPages = $xml.root.pages.page.count
$currentDT = Get-Date -Format "dd/MM/yyyy hh:mm:ss"
write-host "`nTraitement des pages : $currentDT"  -ForegroundColor Yellow
Foreach ($page in $xml.root.pages.page){
    $counter++
    Write-Progress -Activity "Pages" -Status "$counter / $countPages" -PercentComplete (($counter*100)/$countPages)
    tranform($page)
}

$currentDT = Get-Date -Format "dd/MM/yyyy hh:mm:ss"
write-host "`nTraitement terminé : $currentDT"  -ForegroundColor Yellow


## formate le fichier de sortie pour avoir les accents corrects
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

## sauvegarde d'un fichier avec uniquement les pages
$pages = $xml.clone() ## duplique le XML pour effacement partiel
$pages.root.SelectNodes("posts") | %{$_.ParentNode.RemoveChild($_)} | Out-Null ## suppression des articles
$swPages = New-Object System.IO.StreamWriter("export_pages.xml", $false, $utf8WithoutBom)
$pages.Save($swPages)
$swPages.close()

## sauvegarde d'un fichier avec uniquement les articles
$xml.root.SelectNodes("pages") | %{$_.ParentNode.RemoveChild($_)} | Out-Null ## suppression des pages
$swPosts = New-Object System.IO.StreamWriter("export_posts.xml", $false, $utf8WithoutBom)
$xml.Save($swPosts)
$swPosts.close()


## sauvegarde d'un fichier avec uniquement les commentaires
# Nettoyage des réponses inutiles puisque extraites au niveau 0 
Foreach($comment in $xmlComments.comments.comment){
    $comment.SelectNodes("replies") | %{$_.ParentNode.RemoveChild($_)} | Out-Null
}
$swComments = New-Object System.IO.StreamWriter("export_comments.xml", $false, $utf8WithoutBom)
$xmlComments.Save($swComments)
$swComments.close()
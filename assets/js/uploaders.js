// External upload client for TabletapWeb.Manager.MenuLive's photo field
// (library-docs.md "ex_aws_s3 (photos)" — direct-to-bucket PUT, the
// server never sees the file bytes). Works unchanged against either
// storage adapter: Tabletap.Storage.S3 hands out a real Supabase
// presigned URL, Tabletap.Storage.Local hands out a same-origin URL
// that behaves the same way from the client's point of view.
let Uploaders = {}

Uploaders.S3 = function (entries, onViewError) {
  entries.forEach(entry => {
    let {url} = entry.meta
    let xhr = new XMLHttpRequest()
    onViewError(() => xhr.abort())

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        entry.progress(100)
      } else {
        entry.error()
      }
    }
    xhr.onerror = () => entry.error()
    xhr.upload.addEventListener("progress", event => {
      if (event.lengthComputable) {
        let percent = Math.round((event.loaded / event.total) * 100)
        if (percent < 100) entry.progress(percent)
      }
    })

    xhr.open("PUT", url, true)
    xhr.send(entry.file)
  })
}

export default Uploaders
